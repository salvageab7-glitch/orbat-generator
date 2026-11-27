/// ORBAT JSON Schema（结构契约，不含业务红牌/warn）。
///
/// 用途：
///   · Agent/编辑器在写 JSON 时先发现结构错误；
///   · `orbat-cli.exe schema --out orbat.schema.json` 导出；
///   · 业务校验（注释长度、SIDC 语义、重名等）仍由 `OrbatValidator` 负责。
///
/// 约束：
///   · 根节点可有 `commandLevels`；子节点不允许；
///   · `options` 严格只允许 7 键，防止渲染器被杂键弄崩；
///   · `sidc` 必须是 30 位数字字符串；
///   · `additionalInformation` 的 12 汉字/20 字母由业务校验判断，
///     Schema 只做宽松的 120 字符上限。
const String kOrbatSchemaVersion = '2026-11-27-p2';

const String kOrbatSchemaJson = r'''{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://orbat-generator.local/schema/orbat.schema.json",
  "title": "ORBAT tree",
  "description": "ORBAT Generator JSON structure. Business validation still applies.",
  "type": "object",
  "$ref": "#/definitions/root",
  "definitions": {
    "root": {
      "type": "object",
      "required": ["options", "subOrganizations"],
      "additionalProperties": false,
      "properties": {
        "commandLevels": {
          "type": "string",
          "enum": ["1", "2", "3", "4"],
          "description": "Root only. 1/4/empty are normalized to 3; 2 is preserved."
        },
        "options": { "$ref": "#/definitions/options" },
        "subOrganizations": {
          "type": "array",
          "items": { "$ref": "#/definitions/node" }
        }
      }
    },
    "node": {
      "type": "object",
      "required": ["options", "subOrganizations"],
      "additionalProperties": false,
      "properties": {
        "options": { "$ref": "#/definitions/options" },
        "subOrganizations": {
          "type": "array",
          "items": { "$ref": "#/definitions/node" }
        }
      }
    },
    "options": {
      "type": "object",
      "required": ["uniqueDesignation", "sidc"],
      "additionalProperties": false,
      "properties": {
        "sidc": {
          "type": "string",
          "pattern": "^[0-9]{30}$",
          "description": "30-digit SIDC. Use 0-based positions per docs/agent-contract."
        },
        "uniqueDesignation": {
          "type": "string",
          "minLength": 1,
          "maxLength": 200
        },
        "additionalInformation": {
          "type": "string",
          "maxLength": 120,
          "description": "Business limit: 12 CJK / 20 Latin letters."
        },
        "dashed": { "type": "boolean" },
        "outline": { "type": "boolean" },
        "plain-text-mode": { "type": "boolean" },
        "showMapLabels": { "type": "boolean" }
      }
    }
  }
}
''';
