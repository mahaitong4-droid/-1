// 地推商圈分析 - 前端逻辑
// 地图层用 Leaflet（开源免费），底图可切天地图/高德瓦片/OSM，不再依赖高德 JS API。
(async function () {
  const $ = (id) => document.getElementById(id);
  const statusEl = $("status");

  function setStatus(msg, cls = "") {
    statusEl.className = "status " + cls;
    statusEl.textContent = msg;
  }

  // ---------- 0. Leaflet 检查 ----------
  if (!window.L) {
    setStatus("地图库 Leaflet 没加载成功，请确认 frontend/vendor/leaflet/ 目录完整（更新代码时可能漏拷）", "error");
    return;
  }

  // ---------- 1. 拉后端配置 ----------
  let cfg, status;
  try {
    const [rc, rs] = await Promise.all([fetch("/api/config"), fetch("/api/status")]);
    if (!rc.ok || !rs.ok) throw new Error("配置接口失败");
    cfg = await rc.json();
    status = await rs.json();
  } catch (e) {
    setStatus("无法连接后端: " + e.message, "error");
    return;
  }
  renderMode(status);
  if (status.default_city) $("city").value = status.default_city;

  // ---------- 2. 初始化地图 ----------
  const map = L.map("map", {
    center: [28.228, 112.939], // 长沙。注意 Leaflet 用 [lat, lng]
    zoom: 12,
    zoomControl: true,
  });
  buildBaseLayers(map, cfg);
  window.addEventListener("resize", () => map.invalidateSize());

  // 图层组：每次分析前清空
  const overlay = L.layerGroup().addTo(map);
  let currentReport = null;

  // ---------- 3. 绑定按钮 ----------
  $("runBtn").addEventListener("click", async () => {
    const city = $("city").value.trim() || "长沙";
    const region = $("region").value.trim();
    const budget = parseInt($("budget").value, 10) || 30;

    $("runBtn").disabled = true;
    setStatus("抓取 POI + 打分中（深度越大越慢，请耐心等待）...");
    overlay.clearLayers();

    try {
      const t0 = Date.now();
      const resp = await fetch("/api/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ city, region: region || null, budget }),
      });
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({ detail: resp.statusText }));
        throw new Error(err.detail || "分析失败");
      }
      const report = await resp.json();
      currentReport = report;
      renderSummary(report);
      renderAreas(report);
      drawHeatOnMap(report.areas);
      const sec = ((Date.now() - t0) / 1000).toFixed(1);
      setStatus(
        `完成（耗时 ${sec}s）: ${report.areas.length}个商圈, ${report.high_demand_total}家高需求商户`,
        "success"
      );
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

  // -------- 地图底图 --------

  function buildBaseLayers(map, cfg) {
    const provider = cfg.map_provider || "tianditu";

    if (provider === "tianditu" && cfg.tianditu_key) {
      const tk = encodeURIComponent(cfg.tianditu_key);
      const wmts = (layer) =>
        `https://t{s}.tianditu.gov.cn/${layer}_w/wmts?SERVICE=WMTS&REQUEST=GetTile` +
        `&VERSION=1.0.0&LAYER=${layer}&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles` +
        `&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk=${tk}`;
      L.tileLayer(wmts("vec"), {
        subdomains: "01234567", maxZoom: 18,
        attribution: '&copy; <a href="https://www.tianditu.gov.cn/">天地图</a>',
      }).addTo(map);
      // 注记层（路名/地名）必须单独叠一层，否则底图上没有字
      L.tileLayer(wmts("cva"), { subdomains: "01234567", maxZoom: 18 }).addTo(map);
      return;
    }

    if (provider === "osm") {
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      }).addTo(map);
      return;
    }

    // 默认 / 兜底：高德瓦片（免 key，坐标同为 GCJ-02）
    L.tileLayer(
      "https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}",
      { subdomains: "1234", maxZoom: 18, attribution: "&copy; 高德地图" }
    ).addTo(map);
  }

  // -------- 渲染逻辑 --------

  function renderMode(status) {
    const bar = $("modeBar");
    bar.hidden = false;
    const badge = status.free
      ? '<span class="badge free">零成本</span>'
      : '<span class="badge paid">含付费接口</span>';
    bar.innerHTML = `${badge}<span class="mode-text">${escapeHtml(status.mode)}</span>`;

    if (status.problems && status.problems.length) {
      $("setupBox").hidden = false;
      const ul = $("setupList");
      ul.innerHTML = "";
      status.problems.forEach((p) => {
        const li = document.createElement("li");
        li.innerHTML = linkify(p);
        ul.appendChild(li);
      });
    }
    if (!status.ready) $("runBtn").disabled = true;
  }

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
    report.areas.forEach((a) => {
      const li = document.createElement("li");
      li.innerHTML = `
        <span class="heat-tag ${a.heat_level}">${heatLabel(a.heat_level)}</span>
        <div class="area-name">${escapeHtml(a.name)}</div>
        <div class="area-meta">${escapeHtml(a.adname || "")} · 共 ${a.total_qualified} 家 · ${a.high_demand}家有需求 · ${(a.demand_ratio * 100).toFixed(0)}%</div>
      `;
      li.addEventListener("click", () => {
        map.setView(toLatLng(a.center), 15);
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

  // 后端给的是 [lng, lat]，Leaflet 要 [lat, lng]，统一从这里转，别在别处手写
  function toLatLng(center) {
    return [center[1], center[0]];
  }

  function drawHeatOnMap(areas) {
    if (!areas.length) return;
    const latlngs = [];

    areas.forEach((a) => {
      const color = heatColor(a.heat_level);
      const pos = toLatLng(a.center);
      // 半径根据商户数缩放：5家≈400m，50家≈1300m
      const radius = Math.min(1500, 300 + a.total_qualified * 20);

      const circle = L.circle(pos, {
        radius,
        color,
        weight: 2,
        opacity: 0.6,
        fillColor: color,
        fillOpacity: 0.22,
      }).addTo(overlay);
      circle.on("click", () => showDetail(a));

      L.marker(pos, {
        interactive: false,
        icon: L.divIcon({
          className: "ms-label-wrap",
          html: `<div class="ms-label" style="background:${color}">${escapeHtml(a.name)} ${a.high_demand}/${a.total_qualified}</div>`,
          iconSize: null,
        }),
      }).addTo(overlay);

      latlngs.push(pos);
    });

    map.fitBounds(L.latLngBounds(latlngs), { padding: [40, 40] });
  }

  function showDetail(area) {
    $("d-title").textContent = area.name;
    $("d-ad").textContent = area.adname
      ? `${area.adname} · 分组方式：${area.grouping || "-"}`
      : `分组方式：${area.grouping || "-"}`;
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
        <td class="score" title="${escapeHtml(m.reason || "")}">${m.labor_score}</td>
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

  // 把提示语里的 http(s) 链接变成可点的 a 标签（先转义，再替换，避免 XSS）
  function linkify(text) {
    return escapeHtml(text).replace(
      /https?:\/\/[^\s，。）)]+/g,
      (u) => `<a href="${u}" target="_blank" rel="noopener">${u}</a>`
    );
  }

})();
