// 地推商圈分析 - 前端逻辑
(async function () {
  const $ = (id) => document.getElementById(id);
  const statusEl = $("status");

  function setStatus(msg, cls = "") {
    statusEl.className = "status " + cls;
    statusEl.textContent = msg;
  }

  // 1. 拉取后端配置（包含高德key和安全密钥）
  let cfg;
  try {
    const r = await fetch("/api/config");
    if (!r.ok) throw new Error("配置接口失败");
    cfg = await r.json();
  } catch (e) {
    setStatus("无法连接后端: " + e.message, "error");
    return;
  }

  // 2. 加载高德 JS API（带 securityJsCode）
  window._AMapSecurityConfig = { securityJsCode: cfg.amap_security_code || "" };
  await loadAmap(cfg.amap_js_key);

  // 3. 初始化地图（默认长沙中心，使用标准样式以显示街道/商户名）
  const map = new AMap.Map("map", {
    zoom: 12,
    center: [112.939, 28.228], // 长沙
    viewMode: "2D",
    dragEnable: true,
    zoomEnable: true,
    scrollWheel: true,
    doubleClickZoom: true,
    keyboardEnable: true,
    jogEnable: true,
    showLabel: true,
    features: ["bg", "point", "road", "building"],
  });
  // 让地图大小变化时自适应
  window.addEventListener("resize", () => map.resize());

  let circleLayer = [];
  let markerLayer = [];
  let currentReport = null;

  // 4. 绑定按钮
  $("runBtn").addEventListener("click", async () => {
    const city = $("city").value.trim() || "长沙";
    const region = $("region").value.trim();
    const maxPages = parseInt($("maxPages").value, 10) || 10;

    $("runBtn").disabled = true;
    setStatus("抓取POI + AI分类中（深度越大越慢，请耐心等待）...");
    clearMapLayers();

    try {
      const t0 = Date.now();
      const resp = await fetch("/api/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ city, region: region || null, max_pages: maxPages }),
      });
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({ detail: resp.statusText }));
        throw new Error(err.detail || "分析失败");
      }
      const report = await resp.json();
      currentReport = report;
      renderSummary(report);
      renderAreas(report);
      drawHeatOnMap(map, report.areas);
      const sec = ((Date.now() - t0) / 1000).toFixed(1);
      setStatus(`完成（耗时 ${sec}s）: ${report.areas.length}个商圈, ${report.high_demand_total}家高需求商户`, "success");
    } catch (e) {
      setStatus("出错: " + e.message, "error");
    } finally {
      $("runBtn").disabled = false;
    }
  });

  // 关闭弹窗
  $("modalClose").addEventListener("click", () => ($("detailModal").hidden = true));
  $("detailModal").addEventListener("click", (e) => {
    if (e.target.id === "detailModal") $("detailModal").hidden = true;
  });

  // -------- 渲染逻辑 --------

  function renderSummary(report) {
    $("summary").hidden = false;
    $("sum-total").textContent = report.total_pois;
    $("sum-qualified").textContent = report.qualified;
    $("sum-high").textContent = report.high_demand_total;
    $("sum-ratio").textContent = (report.high_demand_ratio * 100).toFixed(1) + "%";
    $("ex-tea").textContent = report.excluded["奶茶茶饮"] || 0;
    $("ex-braised").textContent = report.excluded["卤味熟食"] || 0;
    $("ex-chain").textContent = report.excluded["连锁餐饮"] || 0;
  }

  function renderAreas(report) {
    $("areas-panel").hidden = false;
    const ul = $("area-list");
    ul.innerHTML = "";
    report.areas.forEach((a, idx) => {
      const li = document.createElement("li");
      li.innerHTML = `
        <span class="heat-tag ${a.heat_level}">${heatLabel(a.heat_level)}</span>
        <div class="area-name">${escapeHtml(a.name)}</div>
        <div class="area-meta">${escapeHtml(a.adname || "")} · 共 ${a.total_qualified} 家 · ${a.high_demand}家有需求 · ${(a.demand_ratio * 100).toFixed(0)}%</div>
      `;
      li.addEventListener("click", () => {
        map.setZoomAndCenter(15, a.center);
        showDetail(a);
      });
      ul.appendChild(li);
    });
  }

  function heatLabel(lvl) {
    return lvl === "high" ? "高" : lvl === "mid" ? "中" : "低";
  }

  function heatColor(lvl) {
    return lvl === "high" ? "#ef4444" : lvl === "mid" ? "#f59e0b" : "#94a3b8";
  }

  function clearMapLayers() {
    circleLayer.forEach((c) => map.remove(c));
    markerLayer.forEach((m) => map.remove(m));
    circleLayer = [];
    markerLayer = [];
  }

  function drawHeatOnMap(map, areas) {
    if (!areas.length) return;
    const bounds = new AMap.Bounds(
      [areas[0].center[0], areas[0].center[1]],
      [areas[0].center[0], areas[0].center[1]],
    );

    areas.forEach((a) => {
      const color = heatColor(a.heat_level);
      // 半径根据商户数缩放：5家=400m，50家=1200m
      const radius = Math.min(1500, 300 + a.total_qualified * 20);
      const circle = new AMap.Circle({
        center: a.center,
        radius,
        strokeColor: color,
        strokeOpacity: 0.6,
        strokeWeight: 2,
        fillColor: color,
        fillOpacity: 0.22,
        cursor: "pointer",
      });
      circle.on("click", () => showDetail(a));
      map.add(circle);
      circleLayer.push(circle);

      // 中心点label
      const marker = new AMap.Marker({
        position: a.center,
        content: `<div class="ms-label" style="background:${color};color:#fff;padding:2px 6px;border-radius:10px;font-size:11px;white-space:nowrap;font-weight:600;pointer-events:none">${escapeHtml(a.name)} ${a.high_demand}/${a.total_qualified}</div>`,
        anchor: "center",
        offset: new AMap.Pixel(0, 0),
        clickable: false,
      });
      map.add(marker);
      markerLayer.push(marker);

      bounds.extend(a.center);
    });

    map.setBounds(bounds, false, [40, 40, 40, 40]);
  }

  function showDetail(area) {
    $("d-title").textContent = area.name;
    $("d-ad").textContent = area.adname || "";
    $("d-total").textContent = area.total_qualified;
    $("d-high").textContent = area.high_demand;
    $("d-ratio").textContent = (area.demand_ratio * 100).toFixed(1) + "%";
    $("d-avg").textContent = area.avg_labor_score;

    const tbody = $("d-tbody");
    tbody.innerHTML = "";
    area.top_merchants.forEach((m) => {
      const tr = document.createElement("tr");
      const q58 = encodeURIComponent(m.name);
      const qmt = encodeURIComponent(m.name + " " + (m.address || ""));
      tr.innerHTML = `
        <td>${escapeHtml(m.name)}</td>
        <td>${escapeHtml(m.address || "-")}</td>
        <td>${m.labor_score}</td>
        <td class="verify">
          <a href="https://m.58.com/cs/job/?key=${q58}" target="_blank" rel="noopener">58</a>
          <a href="https://www.meituan.com/s/${qmt}" target="_blank" rel="noopener">美团</a>
          <a href="https://www.amap.com/search?query=${q58}" target="_blank" rel="noopener">高德</a>
        </td>
      `;
      tbody.appendChild(tr);
    });

    $("detailModal").hidden = false;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function loadAmap(key) {
    return new Promise((resolve, reject) => {
      if (window.AMap) return resolve();
      const s = document.createElement("script");
      s.src = `https://webapi.amap.com/maps?v=2.0&key=${encodeURIComponent(key)}`;
      s.onload = resolve;
      s.onerror = () => reject(new Error("加载高德JS API失败，请检查Key和securityJsCode"));
      document.head.appendChild(s);
    });
  }
})();
