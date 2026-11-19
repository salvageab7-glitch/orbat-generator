#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <gdiplus.h>
#include <shlobj.h>

#include <fstream>
#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "gdiplus.lib")

namespace {

// GDI+ 全局初始化：进程内只做一次，退出时不 Shutdown（进程结束自动回收）。
void EnsureGdiplus() {
  static bool initialized = false;
  if (initialized) return;
  initialized = true;
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  Gdiplus::GdiplusStartup(&token, &input, nullptr);
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int len = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                      static_cast<int>(text.size()), nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      out.data(), len);
  return out;
}

// CF_HDROP：让"粘贴"得到一个文件对象（资源管理器/微信文件传输均可）
HGLOBAL CreateDropFiles(const std::wstring& path) {
  const size_t path_bytes = (path.size() + 1) * sizeof(wchar_t);
  const size_t total = sizeof(DROPFILES) + path_bytes + sizeof(wchar_t);
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total);
  if (!mem) return nullptr;
  auto* df = static_cast<DROPFILES*>(GlobalLock(mem));
  if (!df) {
    GlobalFree(mem);
    return nullptr;
  }
  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;
  auto* dst = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(df) +
                                         sizeof(DROPFILES));
  memcpy(dst, path.c_str(), path_bytes);
  dst[path.size()] = L'\0';
  GlobalUnlock(mem);
  return mem;
}

// CF_DIB：让"粘贴"直接得到图片（Word/微信输入框/画图 都能用）
//
// 透明像素统一压到白底：CF_DIB 的 32bpp BI_RGB 在各类宿主对 alpha 处理不一致，
// 压白底能保证任何地方粘出来都不会变成黑块。
HGLOBAL CreateDib(const std::wstring& path) {
  EnsureGdiplus();
  std::unique_ptr<Gdiplus::Bitmap> bitmap(
      Gdiplus::Bitmap::FromFile(path.c_str()));
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) return nullptr;

  HBITMAP handle = nullptr;
  if (bitmap->GetHBITMAP(Gdiplus::Color(255, 255, 255), &handle) !=
          Gdiplus::Ok ||
      handle == nullptr) {
    return nullptr;
  }

  BITMAP bm = {};
  if (GetObject(handle, sizeof(bm), &bm) == 0) {
    DeleteObject(handle);
    return nullptr;
  }
  const int width = bm.bmWidth;
  const int height = bm.bmHeight;
  if (width <= 0 || height <= 0) {
    DeleteObject(handle);
    return nullptr;
  }

  BITMAPINFOHEADER header = {};
  header.biSize = sizeof(BITMAPINFOHEADER);
  header.biWidth = width;
  header.biHeight = height;  // 正数 = 自下而上，符合 CF_DIB 约定
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = BI_RGB;
  header.biSizeImage = static_cast<DWORD>(width) * height * 4;

  const size_t pixels = header.biSizeImage;
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPINFOHEADER) + pixels);
  if (!mem) {
    DeleteObject(handle);
    return nullptr;
  }
  void* dst = GlobalLock(mem);
  if (!dst) {
    GlobalFree(mem);
    DeleteObject(handle);
    return nullptr;
  }
  memcpy(dst, &header, sizeof(BITMAPINFOHEADER));

  BITMAPINFO info = {};
  info.bmiHeader = header;
  HDC dc = GetDC(nullptr);
  GetDIBits(dc, handle, 0, static_cast<UINT>(height),
            static_cast<BYTE*>(dst) + sizeof(BITMAPINFOHEADER), &info,
            DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  GlobalUnlock(mem);
  DeleteObject(handle);
  return mem;
}

// 注册格式 "PNG"：保留原始无损像素，Chrome/Word 等优先用它
HGLOBAL CreatePngBlob(const std::wstring& path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) return nullptr;
  const std::streamsize size = file.tellg();
  if (size <= 0) return nullptr;
  file.seekg(0, std::ios::beg);
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, static_cast<SIZE_T>(size));
  if (!mem) return nullptr;
  void* dst = GlobalLock(mem);
  if (!dst) {
    GlobalFree(mem);
    return nullptr;
  }
  file.read(static_cast<char*>(dst), size);
  GlobalUnlock(mem);
  if (!file) {
    GlobalFree(mem);
    return nullptr;
  }
  return mem;
}

// 把 PNG 同时以多种格式放进剪贴板；返回是否至少写入成功一种
bool CopyPngToClipboard(HWND hwnd, const std::wstring& path) {
  if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) return false;

  HGLOBAL drop = CreateDropFiles(path);
  HGLOBAL dib = CreateDib(path);
  HGLOBAL png = CreatePngBlob(path);
  if (!drop && !dib && !png) return false;

  if (!OpenClipboard(hwnd)) {
    if (drop) GlobalFree(drop);
    if (dib) GlobalFree(dib);
    if (png) GlobalFree(png);
    return false;
  }
  EmptyClipboard();

  bool any = false;
  if (dib) {
    if (SetClipboardData(CF_DIB, dib) != nullptr) {
      dib = nullptr;  // 所有权已移交系统
      any = true;
    }
  }
  if (drop) {
    if (SetClipboardData(CF_HDROP, drop) != nullptr) {
      drop = nullptr;
      any = true;
    }
  }
  if (png) {
    const UINT png_format = RegisterClipboardFormatW(L"PNG");
    if (png_format != 0 && SetClipboardData(png_format, png) != nullptr) {
      png = nullptr;
      any = true;
    }
  }
  CloseClipboard();

  if (drop) GlobalFree(drop);
  if (dib) GlobalFree(dib);
  if (png) GlobalFree(png);
  return any;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // orbat/clipboard：Dart 侧「一键复制 PNG」的落地实现。
  // 不引入第三方剪贴板插件（避免为一个小功能背上 Rust/CMake 重依赖）。
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "orbat/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "copyImageFile") {
          result->NotImplemented();
          return;
        }
        std::string utf8_path;
        if (const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto it = args->find(flutter::EncodableValue("path"));
          if (it != args->end()) {
            if (const auto* value = std::get_if<std::string>(&it->second)) {
              utf8_path = *value;
            }
          }
        }
        if (utf8_path.empty()) {
          result->Error("bad_args", "missing path");
          return;
        }
        const std::wstring wide_path = Utf8ToWide(utf8_path);
        HWND hwnd = flutter_controller_
                        ? flutter_controller_->view()->GetNativeWindow()
                        : nullptr;
        result->Success(
            flutter::EncodableValue(CopyPngToClipboard(hwnd, wide_path)));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    clipboard_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
