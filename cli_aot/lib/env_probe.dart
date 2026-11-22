import 'core/app_paths.dart';
import 'dart:io';
void main() { print('env=${Platform.environment['ORBAT_OUTPUT_DIR']}'); print('dir=${ensureArchiveDir()}'); }
