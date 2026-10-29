/* MDC map: GTA V satellite map (html/map, from the satellite map textures) + live layers.
   World coordinate -> SVG: x' = (x + 3600) * 0.1, y' = (7200 - y) * 0.1  (790 x 1110 units) */
const MAP = (() => {
  const W = 790, H = 1110;
  const toSvg = (x, y) => [(x + 3600) * 0.1, (7200 - y) * 0.1];
  const toWorld = (sx, sy) => [sx * 10 - 3600, 7200 - sy * 10];
  const DISTRICTS = [
    ['DOWNTOWN', 200, -900], ['VESPUCCI', -1250, -1300], ['DEL PERRO', -1550, -650], ['ROCKFORD HILLS', -850, -150],
    ['VINEWOOD', 300, 250], ['BURTON', -450, -300], ['MIRROR PARK', 1100, -550], ['LA MESA', 800, -1200],
    ['STRAWBERRY', 150, -1350], ['DAVIS', 100, -1700], ['LITTLE SEOUL', -700, -900], ['EAST VINEWOOD', 900, -100],
    ['CYPRESS FLATS', 800, -2100], ['LSIA', -1100, -2700], ['TERMINAL', 900, -3000], ['VINEWOOD HILLS', 0, 800],
    ['RICHMAN', -1600, 300], ['PACIFIC BLUFFS', -2000, -300], ['CHUMASH', -3150, 1100], ['TATAVIAM', 1900, 400],
    ['SANDY SHORES', 1850, 3700], ['GRAPESEED', 1700, 4800], ['PALETO BAY', -200, 6350], ['HARMONY', 550, 2700],
    ['MOUNT CHILIAD', 500, 5550], ['FORT ZANCUDO', -2200, 3100], ['ALAMO SEA', 1300, 4100], ['GRAND SENORA', 1500, 2500],
    ['MOUNT JOSIAH', -1100, 4500], ['PALOMINO', 2800, -700], ['PACIFIC OCEAN', -3400, -1800],
  ];
  let postals = [], loading = null;

  // Satellite map (minimap_0_0 … minimap_2_1 textures).
  // GTA minimap grid: top-left corner (-4140, 8400), each tile 4500 x 4500 units, 2 columns x 3 rows.
  const SAT = { x0: -4140, y0: 8400, w: 9000, h: 13500, cols: 8, rows: 12 };
  const [SX, SY] = toSvg(SAT.x0, SAT.y0);
  const SW = SAT.w * 0.1, SH = SAT.h * 0.1, TW = SW / SAT.cols, TH = SH / SAT.rows;

  function load(url) {
    if (loading) return loading;
    loading = fetch(url).then(r => r.json()).then(list => {
      postals = (Array.isArray(list) ? list : []).filter(p => isFinite(p.x) && isFinite(p.y))
        .map(p => { const [sx, sy] = toSvg(+p.x, +p.y); return { code: String(p.code), x: +p.x, y: +p.y, sx, sy }; });
    }).catch(() => { postals = []; });
    return loading;
  }

  function nearest(x, y) {
    let best = null, bd = Infinity;
    for (const p of postals) { const dx = p.x - x, dy = p.y - y, d = dx * dx + dy * dy; if (d < bd) { bd = d; best = p; } }
    return best;
  }

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  let uid = 0;

  class View {
    constructor(svg, o = {}) {
      this.svg = svg; this.o = o; this.id = 'm' + (++uid);
      this.vb = { x: 150, y: 688, w: 400 };
      this.layers = Object.assign({ units: true, calls: true, routes: true, rings: true, postals: false, labels: false }, o.layers || {});
      this.data = null; this.theme = 'night';
      this.svg.innerHTML = '';
      if (o.interactive) this.bind();
    }
    ensureBase() {
      if (this.based === 'sat' + postals.length) return;
      this.based = 'sat' + postals.length;
      this.tiles = {};
      this.svg.innerHTML = `<rect x="${SX - 4000}" y="${SY - 4000}" width="${SW + 8000}" height="${SH + 8000}" fill="#194978"/>
        <image href="map/overview.jpg" x="${SX}" y="${SY}" width="${SW}" height="${SH}" preserveAspectRatio="none"/>
        <g class="tiles"></g>
        <g class="dots" fill="#ffd166" opacity=".85"></g>
        <g class="dist" fill="#ffffff" stroke="#000" stroke-width=".35" paint-order="stroke" font-family="DejaVu Sans, Arial" font-weight="bold" letter-spacing="1"></g>
        <g class="pcode" fill="#ffd166" stroke="#000" stroke-width=".3" paint-order="stroke" font-family="DejaVu Sans Mono, monospace"></g>
        <g class="ov"></g>`;
      this.gTiles = this.svg.querySelector('.tiles'); this.gDots = this.svg.querySelector('.dots');
      this.gDist = this.svg.querySelector('.dist'); this.gCode = this.svg.querySelector('.pcode'); this.gOv = this.svg.querySelector('.ov');
    }
    // When zoomed in, high-resolution tiles of the visible area are loaded (once loaded, they stay)
    loadTiles() {
      if (1 / this.k() < 2.6) return; // overview is sharp enough
      const c0 = Math.max(0, Math.floor((this.vb.x - SX) / TW)), c1 = Math.min(SAT.cols - 1, Math.floor((this.vb.x + this.vb.w - SX) / TW));
      const r0 = Math.max(0, Math.floor((this.vb.y - SY) / TH)), r1 = Math.min(SAT.rows - 1, Math.floor((this.vb.y + this.vbh - SY) / TH));
      let add = '';
      for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) {
        const key = r + '_' + c; if (this.tiles[key]) continue;
        this.tiles[key] = true;
        add += `<image href="map/t_${key}.jpg" x="${(SX + c * TW).toFixed(3)}" y="${(SY + r * TH).toFixed(3)}" width="${(TW + .05).toFixed(3)}" height="${(TH + .05).toFixed(3)}" preserveAspectRatio="none"/>`;
      }
      if (add) this.gTiles.insertAdjacentHTML('beforeend', add);
    }
    size() { const r = this.svg.getBoundingClientRect(); return { w: r.width || 1, h: r.height || 1 }; }
    k() { return this.vb.w / this.size().w; } // SVG units per screen pixel
    apply() {
      const s = this.size();
      this.vb.w = Math.max(18, Math.min(900, this.vb.w));
      const h = this.vb.w * s.h / s.w;
      this.svg.setAttribute('viewBox', `${this.vb.x.toFixed(2)} ${this.vb.y.toFixed(2)} ${this.vb.w.toFixed(2)} ${h.toFixed(2)}`);
      this.vbh = h;
    }
    center(wx, wy, w) {
      const [sx, sy] = toSvg(wx, wy);
      if (w) this.vb.w = w;
      const s = this.size(); const h = this.vb.w * s.h / s.w;
      this.vb.x = sx - this.vb.w / 2; this.vb.y = sy - h / 2;
      this.apply(); this.draw();
    }
    fit() { this.vb = { x: 150, y: 688, w: 400 }; this.apply(); this.draw(); }
    zoom(f, px, py) {
      const s = this.size();
      const cx = this.vb.x + (px ?? s.w / 2) / s.w * this.vb.w, cy = this.vb.y + (py ?? s.h / 2) / s.h * (this.vb.w * s.h / s.w);
      const nw = Math.max(18, Math.min(900, this.vb.w * f));
      this.vb.x = cx - (cx - this.vb.x) * nw / this.vb.w;
      this.vb.y = cy - (cy - this.vb.y) * nw / this.vb.w;
      this.vb.w = nw; this.apply(); this.draw();
    }
    bind() {
      const svg = this.svg;
      svg.addEventListener('wheel', e => { e.preventDefault(); const r = svg.getBoundingClientRect(); this.zoom(e.deltaY > 0 ? 1.18 : 1 / 1.18, e.clientX - r.left, e.clientY - r.top); }, { passive: false });
      let drag = null;
      svg.addEventListener('mousedown', e => { if (e.button !== 0 || e.target.closest('.mk')) return; drag = { x: e.clientX, y: e.clientY, vx: this.vb.x, vy: this.vb.y, moved: false }; svg.classList.add('drag'); });
      window.addEventListener('mousemove', e => {
        const r = svg.getBoundingClientRect();
        if (this.o.onCursor && e.target.closest && svg.contains(e.target)) {
          const sx = this.vb.x + (e.clientX - r.left) / r.width * this.vb.w, sy = this.vb.y + (e.clientY - r.top) / r.height * this.vbh;
          const [wx, wy] = toWorld(sx, sy); this.o.onCursor(wx, wy, nearest(wx, wy));
        }
        if (!drag) return;
        const k = this.vb.w / r.width;
        if (Math.abs(e.clientX - drag.x) + Math.abs(e.clientY - drag.y) > 3) drag.moved = true;
        this.vb.x = drag.vx - (e.clientX - drag.x) * k; this.vb.y = drag.vy - (e.clientY - drag.y) * k;
        this.apply(); if (!this.raf) this.raf = requestAnimationFrame(() => { this.raf = 0; this.draw(); });
      });
      window.addEventListener('mouseup', () => { if (drag) { drag = null; svg.classList.remove('drag'); } });
      svg.addEventListener('click', e => {
        const m = e.target.closest('.mk'); if (m && this.o.onSelect) this.o.onSelect(m.dataset.t, m.dataset.id);
      });
    }
    setTheme(t) { this.theme = t; } // the satellite map is independent of the theme
    update(data) { this.data = data; this.draw(); }
    draw() {
      if (!this.svg.isConnected) return;
      this.ensureBase(); if (!this.vbh) this.apply();
      this.loadTiles();
      const k = this.k(), d = this.data || {}, L = this.layers;
      const fs = 11 * k, inView = (sx, sy, pad = 20 * k) => sx > this.vb.x - pad && sx < this.vb.x + this.vb.w + pad && sy > this.vb.y - pad && sy < this.vb.y + this.vbh + pad;
      // area names
      this.gDist.setAttribute('font-size', (10 * k).toFixed(2));
      this.gDist.style.display = L.labels && this.vb.w > 60 ? '' : 'none';
      if (!this.distDone || this.distK !== k) {
        this.distK = k; this.distDone = true;
        this.gDist.innerHTML = DISTRICTS.map(([n, x, y]) => { const [sx, sy] = toSvg(x, y); return `<text x="${sx.toFixed(1)}" y="${sy.toFixed(1)}" text-anchor="middle">${n}</text>`; }).join('');
      }
      // postal dots + codes (when zoomed in)
      this.gDots.innerHTML = L.postals ? postals.filter(p => inView(p.sx, p.sy, 0)).slice(0, 1500).map(p => `<circle cx="${p.sx.toFixed(1)}" cy="${p.sy.toFixed(1)}" r="${(2.2 * k).toFixed(2)}"/>`).join('') : '';
      if (L.postals && this.vb.w < 140) {
        const vis = postals.filter(p => inView(p.sx, p.sy, 0));
        this.gCode.setAttribute('font-size', (8.5 * k).toFixed(2));
        this.gCode.innerHTML = vis.slice(0, 500).map(p => `<text x="${(p.sx + 2 * k).toFixed(1)}" y="${(p.sy - 2 * k).toFixed(1)}">${p.code}</text>`).join('');
      } else this.gCode.innerHTML = '';

      const out = [];
      const pill = (sx, sy, text, fg, bg, bd) => {
        const w = (String(text).length * 6.4 + 8) * k, h = 15 * k;
        return `<rect x="${sx.toFixed(2)}" y="${(sy - h / 2).toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" rx="${(3 * k).toFixed(2)}" fill="${bg}" stroke="${bd}" stroke-width="${(1 * k).toFixed(2)}"/>`
          + `<text x="${(sx + 4 * k).toFixed(2)}" y="${(sy + 3.8 * k).toFixed(2)}" font-size="${fs.toFixed(2)}" fill="${fg}" font-family="DejaVu Sans Mono, monospace" font-weight="bold">${esc(text)}</text>`;
      };
      const P = { 3: '#e5484d', 2: '#e09a2b', 1: '#2fae5b' };
      // incident surroundings (approximate location)
      if (L.calls && L.rings) (d.calls || []).forEach(c => {
        if (!c.radius || c.x == null) return;
        const [sx, sy] = toSvg(c.x, c.y), r = c.radius * 0.1;
        out.push(`<circle cx="${sx}" cy="${sy}" r="${r}" fill="${P[c.priority]}1c" stroke="${P[c.priority]}" stroke-width="${(1.2 * k).toFixed(2)}" stroke-dasharray="${(5 * k).toFixed(1)} ${(3 * k).toFixed(1)}"/>`);
      });
      // routes
      if (L.routes) (d.routes || []).forEach(r => {
        const [a, b] = toSvg(r.x1, r.y1), [c, e] = toSvg(r.x2, r.y2);
        out.push(`<line x1="${a}" y1="${b}" x2="${c}" y2="${e}" stroke="#3b82f6" stroke-width="${(2 * k).toFixed(2)}" stroke-dasharray="${(6 * k).toFixed(1)} ${(4 * k).toFixed(1)}"/>`);
        if (r.eta) out.push(pill((a + c) / 2 + 4 * k, (b + e) / 2, r.eta, '#cfe0ff', '#0f1d36', '#3b82f6'));
      });
      // incidents
      if (L.calls) (d.calls || []).forEach(c => {
        if (c.x == null) return;
        const [sx, sy] = toSvg(c.x, c.y);
        if (!inView(sx, sy, 200 * k)) return;
        const col = c.critical ? '#ff3b42' : P[c.priority], sz = (c.id === d.sel ? 8 : 6.5) * k;
        out.push(`<g class="mk" data-t="call" data-id="${c.id}">`);
        if (c.critical || c.id === d.sel) out.push(`<circle class="pulse" cx="${sx}" cy="${sy}" r="${(5 * k).toFixed(2)}" fill="none" stroke="${col}" stroke-width="${(1.5 * k).toFixed(2)}"/>`);
        out.push(`<rect x="${(sx - sz).toFixed(2)}" y="${(sy - sz).toFixed(2)}" width="${(sz * 2).toFixed(2)}" height="${(sz * 2).toFixed(2)}" transform="rotate(45 ${sx} ${sy})" fill="${col}" stroke="#fff" stroke-width="${(1.3 * k).toFixed(2)}"/>`);
        out.push(pill(sx - 8 * k, sy - 15 * k, c.label, '#fff', col + 'dd', col));
        out.push('</g>');
      });
      // units (vehicles)
      if (L.units) (d.units || []).forEach(u => {
        const [sx, sy] = toSvg(u.x, u.y);
        if (!inView(sx, sy, 100 * k)) return;
        const s = 7 * k;
        out.push(`<g class="mk" data-t="unit" data-id="${esc(u.key)}">`);
        if (u.mine) out.push(`<circle cx="${sx}" cy="${sy}" r="${(10 * k).toFixed(2)}" fill="none" stroke="#fff" stroke-width="${(1.2 * k).toFixed(2)}"/>`);
        out.push(`<path transform="translate(${sx.toFixed(2)} ${sy.toFixed(2)}) rotate(${(-u.h || 0).toFixed(0)})" d="M0,${-s} L${s * .75},${s * .8} L0,${s * .4} L${-s * .75},${s * .8} Z" fill="${u.color}" stroke="#000" stroke-width="${(1 * k).toFixed(2)}"/>`);
        out.push(pill(sx + 9 * k, sy + 9 * k, u.label, '#e2e9f2', '#0b1118e6', u.color));
        out.push('</g>');
      });
      // me (on-foot position)
      if (d.me) {
        const [sx, sy] = toSvg(d.me.x, d.me.y);
        out.push(`<circle cx="${sx}" cy="${sy}" r="${(4.5 * k).toFixed(2)}" fill="#fff" stroke="#1d4ed8" stroke-width="${(2 * k).toFixed(2)}"/>`);
      }
      this.gOv.innerHTML = out.join('');
    }
  }
  return { load, View, toSvg, toWorld, nearest, get postals() { return postals; } };
})();
