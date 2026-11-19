# SIDC 权威对应表（spatialillusions.com/unitgenerator）

> 数据源：<https://spatialillusions.com/unitgenerator/>（site 内置 milsymbol / MIL-STD-2525D 码表）  
> 抓取日期：2026-11-19　用途：SIDC 30 位码「主实体段（位 10-15）」与「梯队段（位 8-9）」的权威对应。

30 位结构：`1303` + 符号集(10陆/01空) + `00` + **梯队(2)** + **主实体(6)** + 类型(2) + 机动(2) + 扇区(2) + `00000000`

> ### ⛔ 修饰位全部禁用（2026-11-19 用户明令）
> **主实体 6 位之后的 14 位必须全 0**（类型2+机动2+扇区2+保留8），禁用一切"小标志"（履带04、轮式05、火箭炮类型41、扇区01 等）。载具/口径/火箭炮细节写进名称。
> 例：摩托化步兵 `130310001612110400000000000000`、自行火炮 `130310001613030100000000000000`、火箭炮 `130310001613030000000000000000`（站点无独立火箭炮码，靠名称区分）。
> `validate` 对修饰位非零只报 warn（不拦截），历史数据文件仍可出图。

## 一、梯队码（Locations / Echelon，位 8-9）

| 码 | 站点英文 | 中文 |
|---|---|---|
| `00` | Unspecified | 未指定 |
| `11` | Team/Crew | 组/车组 |
| `12` | Squad | 班 |
| `13` | Section | 组/小队(分排) |
| `14` | Platoon/Detachment | 排/分遣队 |
| `15` | Company/Battery/Troop | 连/炮兵连/骑兵连 |
| `16` | Battalion/Squadron | 营/骑兵中队 |
| `17` | Regiment/Group | 团/群 |
| `18` | Brigade | 旅 |
| `21` | Division | 师 |
| `22` | Corps/MEF | 军/军团/陆战远征队 |
| `23` | Army | 集团军 |
| `24` | Army Group/Front | 方面军/集团军群 |
| `25` | Region/Theater | 战区/军区 |
| `26` | Command | 总指挥部 |

> 19、20 在渲染器中不使用；站点 15 档 `11–18, 21–26` + `00` 未指定，与项目 `kEchelon` 完全一致。

## 二、陆上主实体（符号集 10，位 10-15）

| 码 | 站点官方英文（权威） | 项目 kEntity 中文（若有） | 状态 |
|---|---|---|---|
| `110000` | Command and Control | 指挥/控制/通信(C3)、各级HQ | ✔ |
| `110100` | Broadcast Transmitter Antennae | 通信/信号(旧误码，改用111000) | ✔ |
| `110200` | Civil Affairs | — |  |
| `110300` | Civil–Military Cooperation | — |  |
| `110400` | Information Operations | — |  |
| `110500` | Liaison | 联络(Liaison) | ✔ |
| `110501` | Reconnaissance and Liaison Element | — |  |
| `110600` | Military Information Support Operations (MISO) | — |  |
| `110601` | Broadcast Transmitter Antennae | — |  |
| `110700` | Radio | — |  |
| `110800` | Radio Relay | — |  |
| `110900` | Radio Teletype Center | — |  |
| `111000` | Signal | 通信/信号 | ✔ |
| `111001` | Radio | — |  |
| `111002` | Radio Relay | — |  |
| `111003` | Teletype | — |  |
| `111004` | {Disused} | — |  |
| `111005` | Video Imagery (Combat Camera) | — |  |
| `111100` | {Disused} | — |  |
| `111200` | Video Imagery (Combat Camera) | — |  |
| `111300` | Space | — |  |
| `111400` | Special Troops | — |  |
| `111500` | Multi-Domain Operations | — |  |
| `120000` | Movement and Maneuver | — |  |
| `120100` | Air Assault with Organic Lift | 航空 | ✔ |
| `120200` | Air Traffic Services/Airfield Operations | 空中交通服务/机场作业 | ✔ |
| `120300` | {Disused} | — |  |
| `120400` | Antitank/Antiarmor | 反坦克/ATGM | ✔ |
| `120401` | Armored | 反坦克(突击炮) | ✔ |
| `120402` | Motorized | — |  |
| `120500` | Armor /Mechanized | 装甲(坦克) | ✔ |
| `120501` | Reconnaissance/Cavalry/Scout | 侦察(装甲骑兵) | ✔ |
| `120502` | Amphibious | — |  |
| `120600` | Army Aviation/Aviation Rotary Wing | 陆军航空兵 | ✔ |
| `120601` | Reconnaissance | — |  |
| `120700` | Aviation Composite | — |  |
| `120800` | Aviation Fixed Wing | — |  |
| `120801` | Reconnaissance | — |  |
| `120900` | Combat | — |  |
| `121000` | Combined Arms | 合成/诸兵种合成 | ✔ |
| `121100` | Infantry | 步兵(通用/轻步兵) | ✔ |
| `121101` | Amphibious | — |  |
| `121102` | Armored/Mechanized/Tracked | 装甲/机械化(履带) | ✔ |
| `121103` | Main Gun System | 步兵(特殊变体) | ✔ |
| `121104` | Motorized | 摩托化步兵 | ✔ |
| `121105` | Infantry Fighting Vehicle | 步兵战车(IFV) | ✔ |
| `121106` | Mobile Gun System | — |  |
| `121200` | Observer | — |  |
| `121300` | Reconnaissance/Cavalry/Scout | 侦察/边防 | ✔ |
| `121301` | Reconnaissance and Surveillance | 情报侦察 | ✔ |
| `121302` | Marine | — |  |
| `121303` | Motorized | — |  |
| `121400` | Sea Air Land (SEAL) | — |  |
| `121500` | Sniper | 狙击 | ✔ |
| `121600` | Surveillance | 监视/雷达站(项目约定) |  |
| `121700` | Special Forces | 狙击(旅级) | ✔ |
| `121800` | Special Operations Forces (SOF) | 特种作战 | ✔ |
| `121801` | Fixed Wing MISO | — |  |
| `121802` | Ground | — |  |
| `121803` | {Disused} | — |  |
| `121804` | {Disused} | — |  |
| `121805` | Underwater Demolition | — |  |
| `121900` | Unmanned Aerial Systems | — |  |
| `122000` | Ranger | — |  |
| `130000` | Fires | — |  |
| `130100` | Air Defense | 防空(通用) | ✔ |
| `130101` | Main Gun System | 防空身管武器/高炮 | ✔ |
| `130102` | Missile | 防空导弹 | ✔ |
| `130103` | Air and Missile Defense | 弹炮一体防空 | ✔ |
| `130200` | Air/Land Naval Gunfire Liaison | — |  |
| `130300` | Field Artillery | 炮兵(通用) | ✔ |
| `130301` | Self-Propelled Artillery (Tracked) | 自行火炮(履带式) | ✔ 实测有效码（有图标） |
| `130302` | Field Artillery (legacy) | — | ⚠️ legacy（站点已废止，项目在用） |
| `130303` | Field Artillery (legacy) | — | ⚠️ legacy（站点已废止，项目在用） |
| `130400` | Field Artillery Observer | 炮兵侦察/观测 | ✔ |
| `130500` | Joint Fire Support | 火力支援 | ✔ |
| `130600` | Meteorological | — |  |
| `130700` | Missile | 导弹 | ✔ |
| `130800` | Mortar | 迫击炮 | ✔ |
| `130801` | {Disused} | — |  |
| `130802` | Self-Propelled Wheeled | — |  |
| `130803` | Mortar (legacy) | — | ⚠️ legacy（站点已废止，项目在用） |
| `130900` | Survey | — |  |
| `140000` | Protection | — |  |
| `140100` | Chemical Biological Radiological Nuclear Defense | 防化/化学 | ✔ |
| `140101` | {Disused} | — |  |
| `140102` | Motorized | — |  |
| `140103` | Reconnaissance | — |  |
| `140104` | {Disused} | — |  |
| `140105` | Reconnaissance Equipped | — |  |
| `140106` | Chemical, Biological, Radiological, Nuclear, and High-Yield Explosives | — |  |
| `140200` | Combat Support (Maneuver Enhancement) | — |  |
| `140300` | Criminal Investigation Division | — |  |
| `140400` | Diving | — |  |
| `140500` | Dog | 军犬 | ✔ |
| `140600` | Drilling | — |  |
| `140700` | Engineer | 工兵 | ✔ |
| `140701` | Mechanized | — |  |
| `140702` | Motorized | — |  |
| `140703` | Reconnaissance | — |  |
| `140800` | Explosive Ordnance Disposal (EOD) | 排爆(EOD) | ✔ |
| `140900` | Field Camp Construction | — |  |
| `141000` | Fire Fighting/Fire Protection | — |  |
| `141100` | Geospatial Support/Geospatial Information Support | — |  |
| `141200` | Military Police | 宪兵 | ✔ |
| `141300` | Mine | — |  |
| `141400` | Mine Clearing | — |  |
| `141500` | Mine Launching | — |  |
| `141600` | Mine Laying | — |  |
| `141700` | Security | — |  |
| `141701` | {Disused} | — |  |
| `141702` | Motorized | — |  |
| `141800` | Search and Rescue | — |  |
| `141801` | Isolated Personnel | — |  |
| `141900` | {Disused} | — |  |
| `142000` | Shore Patrol/Security Police | — |  |
| `142100` | Topographic/Geospatial | — |  |
| `142200` | Missile Defense | — |  |
| `150000` | Intelligence | — |  |
| `150100` | Analysis | — |  |
| `150200` | Counterintelligence | 反情报 | ✔ |
| `150300` | Direction Finding | — |  |
| `150400` | Electronic Ranging | — |  |
| `150500` | Electronic Warfare | 电子战 | ✔ |
| `150501` | Analysis | — |  |
| `150502` | Direction Finding | — |  |
| `150503` | Intercept | — |  |
| `150504` | Jamming | — |  |
| `150505` | Search | — |  |
| `150600` | Intercept (Search and Recording) | — |  |
| `150700` | Interrogation | — |  |
| `150800` | Jamming | — |  |
| `150900` | Joint Intelligence Center | — |  |
| `151000` | Military Intelligence | — |  |
| `151100` | Search | — |  |
| `151200` | Sensor | — |  |
| `151300` | Military History | — |  |
| `160000` | Sustainment | 勤务/支援(通用) | ✔ |
| `160100` | Administrative | — |  |
| `160200` | All Classes of Supply | — |  |
| `160300` | {Disused} | — |  |
| `160400` | Ammunition | — |  |
| `160500` | Band | — |  |
| `160501` | Army Music | — |  |
| `160600` | Combat Service Support | 维修保养 | ✔ |
| `160700` | Finance | — |  |
| `160800` | Judge Advocate General | 军法署(JAG) | ✔ |
| `160900` | Labor | — |  |
| `161000` | Laundry/Bath | — |  |
| `161100` | Maintenance | 维修/修理 | ✔ |
| `161200` | Material | — |  |
| `161300` | Medical | 医疗/卫生 | ✔ |
| `161400` | Medical Treatment Facility | — |  |
| `161500` | Morale, Welfare and Recreation | 车辆运输 | ✔ |
| `161600` | Mortuary Affairs | — |  |
| `161700` | Multiple Classes of Supply | — |  |
| `161800` | NATO Supply Class I | 抢修 | ✔ |
| `161900` | NATO Supply Class II | — |  |
| `162000` | NATO Supply Class III | — |  |
| `162100` | NATO Supply Class IV | — |  |
| `162200` | NATO Supply Class V | — |  |
| `162300` | Ordnance | 维修排级 | ✔ |
| `162400` | Personnel Services | — |  |
| `162500` | Petroleum, Oil and Lubricants | — |  |
| `162600` | {Disused} | — |  |
| `162700` | {Disused} | — |  |
| `162800` | Public Affairs/Public Information | — |  |
| `162900` | Quartermaster | — |  |
| `163000` | {Disused} | — |  |
| `163100` | Religious Support | — |  |
| `163200` | Replacement Holding Unit | — |  |
| `163300` | {Disused} | — |  |
| `163400` | {Disused} | — |  |
| `163500` | Joint Information Bureau (JIB) | — |  |
| `163600` | Transportation | 后勤/运输 | ✔ |
| `163601` | Transportation (legacy) | — | ⚠️ legacy（站点已废止，项目在用） |
| `163700` | US Supply Class I | — |  |
| `163800` | {Disused} | — |  |
| `163900` | {Disused} | — |  |
| `164000` | US Supply Class IV | — |  |
| `164100` | {Disused} | — |  |
| `164200` | US Supply Class VI | 弹药 | ✔ |
| `164300` | US Supply Class VII | — |  |
| `164400` | US Supply Class VIII | — |  |
| `164500` | US Supply Class IX | — |  |
| `164600` | US Supply Class X | — |  |
| `164700` | {Disused} | — |  |
| `164800` | Water Purification | — |  |
| `164900` | Broadcast | — |  |
| `165000` | {Disused} | — |  |
| `165100` | Interpreter/Translator | — |  |
| `165200` | Support | 本部/支援 | ✔ |
| `165300` | Army Field Support | — |  |
| `165400` | Contracting Services | — |  |
| `165500` | Parachute Rigger | — |  |
| `165600` | Human Resources | — |  |
| `170000` | Naval | — |  |
| `170100` | Naval | — |  |
| `180000` | Named Headquarters | — |  |
| `180100` | Allied Command Europe Rapid Reaction Corps (ARRC) | — |  |
| `180200` | Allied Command Operations | — |  |
| `180300` | International Security Assistance Force (ISAF) | — |  |
| `180400` | Multinational (MN) | — |  |
| `190000` | Emergency Operation | — |  |
| `200000` | Law Enforcement | — |  |
| `200100` | Bureau of Alcohol, Tobacco, Firearms and Explosives (ATF) (Department of Justice) | — |  |
| `200200` | Border Patrol | — |  |
| `200300` | Customs Service | — |  |
| `200400` | Drug Enforcement Administration (DEA) | — |  |
| `200500` | Department of Justice (DOJ) | — |  |
| `200600` | Federal Bureau of Investigation (FBI) | — |  |
| `200700` | Police | — |  |
| `200800` | Prison | — |  |
| `200900` | United States Secret Service (Treas) (USSS) | — |  |
| `201000` | Transportation Security Administration (TSA) | — |  |
| `201100` | Coast Guard | — |  |
| `201200` | US Marshals Service | — |  |
| `201300` | Internal Security Force | — |  |
| `210000` | Cyber | — |  |

## 三、空中主实体（符号集 01，位 10-15）

| 码 | 站点官方英文（权威） |
|---|---|
| `110000` | Military |
| `110100` | Fixed Wing |
| `110101` | Medical Evacuation (MEDEVAC) |
| `110102` | Attack/Strike |
| `110103` | Bomber |
| `110104` | Fighter |
| `110105` | Fighter/Bomber |
| `110106` | {Disused} |
| `110107` | Cargo |
| `110108` | Electronic Combat (EC)/Jammer |
| `110109` | Tanker |
| `110110` | Patrol |
| `110111` | Reconnaissance |
| `110112` | Trainer |
| `110113` | Utility |
| `110114` | Vertical or Short Take-off and Landing (VSTOL) |
| `110115` | Airborne Command Post (ACP) |
| `110116` | Airborne Early Warning (AEW) |
| `110117` | Antisurface Warfare |
| `110118` | Antisubmarine Warfare |
| `110119` | Communications |
| `110120` | Combat Search and Rescue (CSAR) |
| `110121` | Electronic Support (ES) |
| `110122` | Government |
| `110123` | Mine Countermeasures (MCM) |
| `110124` | Personnel Recovery |
| `110125` | Search and Rescue |
| `110126` | Special Operations Forces |
| `110127` | Ultra Light |
| `110128` | Photographic Reconnaissance |
| `110129` | Very Important Person (VIP) |
| `110130` | Suppression of Enemy Air Defense |
| `110131` | Passenger |
| `110132` | Escort |
| `110133` | Electronic Attack (EA) |
| `110200` | Rotary Wing |
| `110300` | Unmanned Aircraft (UA) / Unmanned Aerial Vehicle (UAV) / Unmanned Aircraft System (UAS) / Remotely Piloted Vehicle (RPV) |
| `110400` | Vertical–Takeoff UAV (VT–UAV) |
| `110500` | Lighter Than Air |
| `110600` | Airship |
| `110700` | Tethered Lighter than Air |
| `120000` | Civilian |
| `120100` | Fixed Wing |
| `120200` | Rotary Wing |
| `120300` | Unmanned Aircraft (UA) / Unmanned Aerial Vehicle (UAV) / Unmanned Aircraft System (UAS) / Remotely Piloted Vehicle (RPV) |
| `120400` | Lighter Than Air |
| `120500` | Airship |
| `120600` | Tethered Lighter than Air |
| `120700` | Medical Evacuation (MEDEVAC) |
| `130000` | Weapon |
| `130100` | Bomb |
| `130200` | Decoy |
| `140000` | Manual Track |

## 四、冲突项裁决结果（2026-11-19 已确认并落地）
> 用户把全部冲突项导入 spatialillusions 网站逐个人眼核对后裁决：**大部分以站点码与官方语义为准**，
> 少数按渲染实测定夺。以下为最终结论，已同步进提示词 / 规则引擎 / `kEntity` / 关键词表。

| 组 | 码 | 最终语义（已落地） | 裁决依据 |
|---|---|---|---|
| A | `110500` | **联络 Liaison**（原误标电子战） | 站点官方 |
| A | `150500` | **电子战**（电子战单位改用此码） | 站点官方 |
| B | `121105` | **步兵战车 IFV**（原误标机步） | 站点官方 |
| B | `121102` | **装甲/机械化(履带)**（原误标轻步兵） | 站点官方 |
| B | `121104` | **摩托化步兵**（原误标步战车） | 站点官方 |
| B | `121100` | 步兵（含**轻步兵**，轻步兵改回此码） | 站点官方 |
| C | `120200` | **空中交通服务/机场作业**（原误标炮兵观察） | 站点官方 |
| C | `130400` | **炮兵侦察/观察**（炮兵观察单位改用此码） | 站点官方 |
| D | `130301` | **自行火炮(履带式)** —— 有实际图标，为有效码（不再标 legacy） | 用户实测推翻站点"无此码" |
| D | `130300` | **炮兵通用码**（成像为卡车炮/轮式，但保留作炮兵通用，不改映射） | 用户裁决 |
| E | `150200` | **反情报 Counterintelligence**（原误标雷达） | 站点官方 |
| E | `121600` | **监视/雷达站**（雷达连/站单位改用此码，因单位集无独立雷达实体） | 用户裁决 |
| F | `160800` | **军法署 JAG**（原误标医疗） | 站点官方 |
| F | `161300` | **医疗/卫生**（医疗与卫生是同一码的两种叫法，如中国"卫生连"） | 用户裁决 |
| G | `111000` | 通信/信号（一致项，保持不变） | 站点官方（一致） |

### 已改动的代码位置（四副本同步：app/lib、app/cli_aot、GitHub导出/lib、GitHub导出/cli_aot）
- `core/sidc_entities.dart`：两表英文名采用站点官方用词（早前已完成）。
- `core/sidc_tables.dart`：`kEntity` 中文职能表 + `kKeywordToEntity` 关键词映射。
- `ai/prompt.dart`：主实体速查表 + 完整实例（装甲步兵营改为 `121105`）。
- `pipeline.dart`：识图提示词主实体速查。
- `core/sidc_rule.dart`：中文/外文兵种规则（自行炮→130301、医疗→161300、雷达→121600、军法→160800、步兵类细分）。
- `core/sidc_audit.dart`：过时注释更新。

### 梯队码
`11–18,21–26` 共 15 档 + `00`，与项目 `kEchelon` **完全一致**，无需改动。`19`/`20` 渲染器不使用。
