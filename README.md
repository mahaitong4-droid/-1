# 地推商圈分析工具

线下地推辅助工具：抓取高德POI → 规则+AI筛选独立餐饮（排除连锁/奶茶/卤味）→ 按商圈聚合"用工需求热度"→ 地图可视化呈现。

**核心场景**：你要在一个城市做日结/短期用工类产品的地推，打开工具选定城市/区域，几分钟后地图上就显示"哪个商圈值得跑、哪些店优先拜访"。

---

## 一、准备工作（10分钟）

### 1. 申请所需 Key

| Key | 用途 | 申请地址 |
|---|---|---|
| 高德 Web服务 Key | 后端调POI接口 | https://console.amap.com/dev/key/app |
| 高德 Web端JS Key + 安全密钥 | 前端地图组件 | 同上（同一应用下添加） |
| DeepSeek API Key | AI分类与用工评分 | https://platform.deepseek.com |

高德 Key 申请细节：
- 同一应用下创建两个 Key，服务平台分别选 **Web服务** 和 **Web端(JS API)**
- Web端Key 创建后，点旁边的「**重置安全密钥**」获取 `securityJsCode`
- 域名白名单留空，本地开发即可使用

### 2. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env，填入上面拿到的4个值
```

### 3. 安装Python依赖（建议Python 3.10+）

```bash
python3 -m venv .venv
source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

---

## 二、启动

```bash
python -m backend.main
```

启动成功后看到类似：
```
INFO:     Uvicorn running on http://0.0.0.0:8000
```

浏览器打开 **http://localhost:8000** 即可。

### 让手机/同事电脑也能访问

服务默认监听 `0.0.0.0`，局域网内其他设备打开 `http://你电脑的内网IP:8000` 就能用（先关闭防火墙或放行8000端口）。

---

## 三、使用流程

1. 打开网页 → 左侧填**城市**（默认长沙）+ 可选**区域**（如"雨花区"）
2. 选**抓取深度**（深=慢但全）→ 点「开始分析」
3. 等待 30秒~3分钟（取决于深度），过程中在跑：
   - 高德拉POI（餐饮大类）
   - 规则层用连锁词库快速筛掉一批
   - 剩下的批量送DeepSeek做分类+用工评分
   - 按"商圈"聚合
4. 完成后地图上出现彩色圆圈：
   - 🔴 红色 = 高匹配商圈（独立餐饮里 ≥50% 有用工需求）
   - 🟠 橙色 = 中等
   - ⚪ 灰色 = 低
5. 点击圆圈或左侧商圈列表 → 弹出该商圈的Top候选商户 + 直接跳转到58/美团/高德验证招聘信息和销量

---

## 四、自定义规则

### 1. 扩充连锁品牌词库

编辑 `data/chain_brands.txt`，按文件顶部说明分组添加品牌名。**新加的品牌立即生效**，下次"开始分析"就会用上。

### 2. 调整"有用工需求"阈值

`backend/analyzer.py` 顶部的 `LABOR_DEMAND_THRESHOLD = 60`，调高=更严格（更少店被算作高需求），调低=更宽松。

### 3. 调整AI提示词

`backend/deepseek.py` 中的 `SYSTEM_PROMPT`，可改"用工需求强度"的判定标准、或追加你独家的筛选维度。

### 4. 修改默认城市

`.env` 中 `DEFAULT_CITY=` 改为你的城市。

---

## 五、合规与边界

- 仅抓取高德开放平台的**公开POI数据**，请求频率受高德官方接口限速保护
- **不抓**美团/大众点评/58/BOSS等需登录或反爬严格的平台；这些平台的验证靠地图上的「58/美团/高德」按钮**手动点击**到对应搜索页人工核实
- 抓取到的商户联系方式仅供个人地推拜访使用，**严禁批量电销/短信骚扰**，否则违反《反电信网络诈骗法》
- 工具纯个人自用，不对外提供服务、不转售数据

---

## 六、项目结构

```
.
├── backend/                # FastAPI 后端
│   ├── main.py              # 主入口 + /api/* 路由
│   ├── config.py            # 环境变量加载
│   ├── amap.py              # 高德POI客户端
│   ├── classifier.py        # 规则筛选（词库）
│   ├── deepseek.py          # AI分类 + 用工评分
│   └── analyzer.py          # 商圈聚合
├── frontend/
│   ├── index.html           # 地图页面
│   ├── app.js               # 前端逻辑
│   └── styles.css
├── data/
│   └── chain_brands.txt     # 连锁/奶茶/卤味品牌词库
├── requirements.txt
├── .env.example             # 环境变量模板
└── README.md
```

---

## 七、常见问题

**Q: 启动报 `RuntimeError: 环境变量 AMAP_BACKEND_KEY 未配置`**  
A: 没建 `.env` 或 key 还是模板默认值。`cp .env.example .env` 后编辑填入真实值。

**Q: 地图加载白屏，控制台报 `INVALID_USER_SCODE`**  
A: 安全密钥 (`AMAP_FRONTEND_SECRET`) 配错了。在高德控制台重置安全密钥后更新 `.env`。

**Q: AI返回慢/超时**  
A: 把"抓取深度"调低，或在 `backend/main.py` 里把 `DeepSeekClassifier.classify_batch` 的 `concurrency` 调大（默认3，可到5-8）。

**Q: 想跑其他城市怎么办？**  
A: 直接前端"城市"框输入城市名（如"成都"、"杭州"）即可，不需要改代码。连锁词库的覆盖度对所有一二线城市基本通用。
