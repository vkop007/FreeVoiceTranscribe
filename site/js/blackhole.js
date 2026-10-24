/* EVENT HORIZON — blackhole.js
   Canvas 2D only, no dependencies, file:// safe.
   Centered horizon / warped accretion disk / starfield parallax.
   Respects prefers-reduced-motion. */
(() => {
  const canvas = document.getElementById("blackhole-canvas");
  if (!canvas) return;
  const ctx = canvas.getContext("2d", { alpha: false });
  if (!ctx) return;

  const mReduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  let w = 0, h = 0, cx = 0, cy = 0, dpr = 1;
  let BH_R = 120, photonR = 0, diskOuter = 0, diskInner = 0, tilt = 0.32;
  let stars = [];
  let mx = 0, my = 0, tmx = 0, tmy = 0;
  let raf = 0;
  let t0 = performance.now();

  // --- stars ---
  function makeStars() {
    const area = w * h;
    const n = Math.min(520, Math.max(180, Math.round(area / 5200)));
    stars = new Array(n);
    // seeded-ish pseudo random without external dep
    let s = 0x9e3779b1 ^ (w * 997) ^ (h * 991);
    function rnd() { s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ s >>> 15, s | 1); t ^= t + Math.imul(t ^ t >>> 7, t | 61); return ((t ^ t >>> 14) >>> 0) / 4294967296; }
    for (let i = 0; i < n; i++) {
      const depth = rnd() * rnd(); // more near than far
      // distribute
      const x = rnd() * w;
      const y = rnd() * h;
      // avoid placing stars dead-center horizon (will be culled anyway)
      const r = (rnd() < 0.82 ? 0.6 + rnd() * 1.0 : 1.4 + rnd() * 1.1);
      const base = 0.28 + rnd() * 0.72;
      const twPhase = rnd() * Math.PI * 2;
      const twSpeed = 0.7 + rnd() * 2.2;
      // warm/cool tint index
      const tint = rnd();
      stars[i] = { x, y, r, base, twPhase, twSpeed, depth, tint };
    }
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    // canvas fills hero section, which is full viewport
    const rect = canvas.getBoundingClientRect();
    // fallback when not yet laid out
    const rw = Math.max(320, Math.round(rect.width || window.innerWidth));
    const rh = Math.max(320, Math.round(rect.height || (window.innerHeight - 58)));
    w = rw; h = rh;
    cx = w * 0.5;
    // hero content is centered; place BH slightly above vertical center for better framing
    cy = h * 0.50;
    // on very short hero, nudge up a bit
    if (h < 560) cy = h * 0.48;

    BH_R = Math.max(72, Math.min(220, Math.min(w, h) * 0.135));
    // slightly oval check for ultra-wide hero
    if (w > h * 1.6) BH_R = Math.min(BH_R, h * 0.26);
    photonR = BH_R * 1.055;
    diskOuter = BH_R * 2.9;
    diskInner = BH_R * 1.34;
    tilt = 0.31;
    // HiDPI backing
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    makeStars();
    // draw immediate so no blank frame
    if (mReduced.matches) drawStatic();
    else if (!raf) drawFrame(0);
  }

  // --- helpers ---
  function lensedOffset(dist) {
    if (dist <= BH_R * 0.98) return null; // occluded
    if (dist >= BH_R * 6.2) return 0;
    // subtle push outward: Einstein deflection approx
    return (BH_R * BH_R) / dist * 0.165;
  }

  function starColor(tint, alpha) {
    // 0..1 tint => cool .. warm
    if (tint < 0.22) return `rgba(180,205,255,${alpha})`; // blue-white
    if (tint < 0.38) return `rgba(210,225,255,${alpha})`;
    if (tint > 0.92) return `rgba(255,210,160,${alpha})`; // warm
    return `rgba(255,255,255,${alpha})`;
  }

  // --- drawing pieces ---
  function drawBackground(t) {
    // base
    ctx.fillStyle = "#05070d";
    ctx.fillRect(0, 0, w, h);

    // faint nebula / dust — cheap radial washes
    const g1 = ctx.createRadialGradient(cx, cy, BH_R * 0.9, cx, cy, Math.max(w, h) * 0.85);
    g1.addColorStop(0, "rgba(18,12,28,0.55)");
    g1.addColorStop(0.22, "rgba(14,18,36,0.32)");
    g1.addColorStop(0.48, "rgba(7,10,20,0.0)");
    ctx.fillStyle = g1;
    ctx.fillRect(0, 0, w, h);

    // second teal wash low
    const g2 = ctx.createRadialGradient(cx, h * 0.92, 40, cx, h * 0.92, h * 0.9);
    g2.addColorStop(0, "rgba(122,211,255,0.06)");
    g2.addColorStop(1, "rgba(0,0,0,0)");
    ctx.fillStyle = g2;
    ctx.fillRect(0, 0, w, h);

    // top-center warm wash
    const g3 = ctx.createRadialGradient(cx, cy * 0.68, BH_R * 1.2, cx, cy * 0.68, h * 0.7);
    g3.addColorStop(0, "rgba(255,122,61,0.07)");
    g3.addColorStop(1, "rgba(0,0,0,0)");
    ctx.fillStyle = g3;
    ctx.fillRect(0, 0, w, h);

    // slow drift — offset starfield subtly by time (parallax base)
    void t;
  }

  function drawStars(t) {
    // mouse-parallax follower lerp
    mx += (tmx - mx) * 0.04;
    my += (tmy - my) * 0.04;

    for (let i = 0; i < stars.length; i++) {
      const s = stars[i];
      // parallax by depth
      const px = s.x + mx * (18 + s.depth * 28);
      const py = s.y + my * (10 + s.depth * 16) + Math.sin(t * 0.06 + s.twPhase * 0.3) * s.depth * 3;

      // wrap
      let x = px, y = py;
      // cheap wrap instead of branch heavy
      if (x < -4) x += w + 8; else if (x > w + 4) x -= w + 8;
      if (y < -4) y += h + 8; else if (y > h + 4) y -= h + 8;

      const dx = x - cx;
      const dy = y - cy;
      const dist = Math.hypot(dx, dy);

      // occlude inside horizon (including slight lensed eclipse)
      if (dist < BH_R * 0.99) continue;

      const extra = lensedOffset(dist);
      if (extra === null) continue;
      let lx = x, ly = y;
      if (extra > 0.2) {
        const ang = Math.atan2(dy, dx);
        const nd = dist + extra;
        lx = cx + Math.cos(ang) * nd;
        ly = cy + Math.sin(ang) * nd;
        // slight chromatic fringe near horizon: nudge horizontal for blue vs red?
        // keep simple: add 0.3px offset for cool stars near ring
      }

      // twinkle
      const tw = 0.68 + 0.32 * Math.sin(t * s.twSpeed * 0.65 + s.twPhase);
      const tw2 = 0.88 + 0.12 * Math.sin(t * 0.9 + s.twPhase * 1.7);
      let a = s.base * tw * tw2;
      // distance fade near ring — add brightness boost at Einstein radius
      if (dist > BH_R * 1.02 && dist < BH_R * 2.2) a *= 1.08;
      // dim very distant
      if (s.depth < 0.12) a *= 0.75;
      a = Math.max(0, Math.min(1, a));

      // lensed stars appear slightly larger near BH
      let rr = s.r;
      if (dist < BH_R * 2.0) rr *= 1.25;
      if (a < 0.06) continue;

      ctx.fillStyle = starColor(s.tint, a * 0.95);
      // round rect fast path: arc is fine for <520 stars
      ctx.beginPath();
      ctx.arc(lx, ly, rr, 0, Math.PI * 2);
      ctx.fill();

      // subtle cross glow for bright stars
      if (rr > 1.35 && a > 0.62) {
        ctx.fillStyle = `rgba(255,255,255,${a * 0.14})`;
        ctx.beginPath();
        ctx.arc(lx, ly, rr * 2.2, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  function drawDiskBack(t) {
    // clip to upper region (behind BH): includes lensed arch
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, w, cy + BH_R * 0.18);
    ctx.clip();

    const lensArch = BH_R * 0.24; // far side lifts above
    const cy0 = cy - lensArch;

    // Back disk as elliptical ring — use scaled context for true elliptical gradient
    ctx.save();
    ctx.translate(cx, cy0);
    ctx.scale(1, tilt);

    // scale-compensated radii remain circular in scaled space
    const outer = diskOuter;
    const inner = diskInner;

    // radial heat gradient
    const rg = ctx.createRadialGradient(0, 0, inner * 0.92, 0, 0, outer);
    // transparent -> hot -> cool outer
    rg.addColorStop(0.00, "rgba(0,0,0,0)");
    rg.addColorStop(0.08, "rgba(255,95,40,0)");
    rg.addColorStop(0.18, "rgba(255,120,45,0.18)");
    rg.addColorStop(0.30, "rgba(255,170,70,0.42)");
    rg.addColorStop(0.46, "rgba(255,200,110,0.72)");
    rg.addColorStop(0.60, "rgba(255,235,170,0.55)");
    rg.addColorStop(0.74, "rgba(140,210,255,0.22)");
    rg.addColorStop(0.88, "rgba(80,160,220,0.08)");
    rg.addColorStop(1.00, "rgba(0,0,0,0)");

    ctx.fillStyle = rg;
    ctx.beginPath();
    // top half only
    ctx.arc(0, 0, outer, Math.PI, Math.PI * 2);
    ctx.arc(0, 0, inner, Math.PI * 2, Math.PI, true);
    ctx.closePath();
    ctx.fill("evenodd");

    // Doppler / beaming modulation — overlay horizontal gradient
    // approaching side (left) brighter, receding (right) dimmer/redder
    const dop = ctx.createLinearGradient(-outer, 0, outer, 0);
    dop.addColorStop(0.00, "rgba(255,255,255,0.00)");
    dop.addColorStop(0.22, "rgba(255,210,120,0.00)");
    dop.addColorStop(0.38, "rgba(255,255,255,0.14)");
    dop.addColorStop(0.50, "rgba(255,255,255,0.06)");
    dop.addColorStop(0.66, "rgba(80,160,255,0.08)");
    dop.addColorStop(1.00, "rgba(0,0,0,0)");
    ctx.globalCompositeOperation = "screen";
    ctx.fillStyle = dop;
    ctx.beginPath();
    ctx.arc(0, 0, outer, Math.PI, Math.PI * 2);
    ctx.arc(0, 0, inner, Math.PI * 2, Math.PI, true);
    ctx.closePath();
    ctx.fill("evenodd");
    ctx.globalCompositeOperation = "source-over";

    // subtle moving knot — orbits slowly (top half only when it swings behind)
    const knotA = (t * 0.38) % (Math.PI * 2);
    // only draw when knot is in upper semicircle
    if (knotA > Math.PI && knotA < Math.PI * 2) {
      const kr = (inner + outer) * 0.5;
      const kx = Math.cos(knotA) * kr;
      const ky = Math.sin(knotA) * kr * 1; // already scaled, so no extra tilt
      // radial falloff
      const kg = ctx.createRadialGradient(kx, ky, 0, kx, ky, BH_R * 0.48);
      kg.addColorStop(0, "rgba(255,255,255,0.55)");
      kg.addColorStop(0.28, "rgba(255,220,150,0.42)");
      kg.addColorStop(0.62, "rgba(255,140,60,0.14)");
      kg.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = kg;
      ctx.beginPath();
      ctx.arc(kx, ky, BH_R * 0.46, 0, Math.PI * 2);
      ctx.fill();
    }

    ctx.restore(); // scale
    ctx.restore(); // clip
  }

  function drawPhotonRingAndHorizon(t) {
    void t;
    // outer lensing glow (subtle Einstein ring bloom)
    ctx.save();
    ctx.shadowColor = "rgba(255,180,120,0.55)";
    ctx.shadowBlur = BH_R * 0.22;
    ctx.strokeStyle = "rgba(255,220,170,0.95)";
    ctx.lineWidth = Math.max(1, BH_R * 0.018);
    ctx.beginPath();
    ctx.arc(cx, cy, photonR, 0, Math.PI * 2);
    ctx.stroke();
    ctx.shadowBlur = 0;

    // second faint outer ring
    ctx.strokeStyle = "rgba(255,180,130,0.22)";
    ctx.lineWidth = Math.max(1, BH_R * 0.010);
    ctx.beginPath();
    ctx.arc(cx, cy, BH_R * 1.13, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();

    // event horizon — absolute black
    ctx.fillStyle = "#000000";
    ctx.beginPath();
    ctx.arc(cx, cy, BH_R, 0, Math.PI * 2);
    ctx.fill();

    // inner edge vignette / depth
    const ig = ctx.createRadialGradient(cx, cy, BH_R * 0.62, cx, cy, BH_R);
    ig.addColorStop(0, "rgba(0,0,0,1)");
    ig.addColorStop(0.76, "rgba(0,0,0,1)");
    ig.addColorStop(0.88, "rgba(20,14,28,0.9)");
    ig.addColorStop(1, "rgba(90,60,40,0.0)");
    ctx.fillStyle = ig;
    ctx.beginPath();
    ctx.arc(cx, cy, BH_R, 0, Math.PI * 2);
    ctx.fill();

    // subtle chromatic fringe at horizon edge (lensing)
    ctx.strokeStyle = "rgba(120,200,255,0.12)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx + 0.6, cy, BH_R - 0.4, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = "rgba(255,120,80,0.10)";
    ctx.beginPath();
    ctx.arc(cx - 0.6, cy, BH_R - 0.4, 0, Math.PI * 2);
    ctx.stroke();

    // corona halo under horizon — thin atmospheric glow
    const hg = ctx.createRadialGradient(cx, cy, BH_R * 0.98, cx, cy, BH_R * 1.42);
    hg.addColorStop(0, "rgba(255,140,70,0.0)");
    hg.addColorStop(0.48, "rgba(255,140,70,0.14)");
    hg.addColorStop(0.62, "rgba(255,200,130,0.08)");
    hg.addColorStop(1, "rgba(0,0,0,0)");
    ctx.fillStyle = hg;
    ctx.beginPath();
    ctx.arc(cx, cy, BH_R * 1.42, 0, Math.PI * 2);
    ctx.arc(cx, cy, BH_R * 0.99, 0, Math.PI * 2, true);
    ctx.fill("evenodd");
  }

  function drawDiskFront(t) {
    // front half: below horizon, appears over the black shadow's lower rim
    ctx.save();
    // clip to lower region, but keep a sliver overlap so disk meets horizon edge softly
    ctx.beginPath();
    ctx.rect(0, cy - BH_R * 0.22, w, h - (cy - BH_R * 0.22));
    ctx.clip();

    const cy0 = cy; // front is not lensed upward
    ctx.save();
    ctx.translate(cx, cy0);
    ctx.scale(1, tilt);
    const outer = diskOuter;
    const inner = diskInner;

    const rg = ctx.createRadialGradient(0, 0, inner * 0.88, 0, 0, outer);
    rg.addColorStop(0.00, "rgba(0,0,0,0)");
    rg.addColorStop(0.10, "rgba(255,110,50,0.10)");
    rg.addColorStop(0.24, "rgba(255,160,65,0.48)");
    rg.addColorStop(0.38, "rgba(255,210,120,0.84)");
    rg.addColorStop(0.54, "rgba(255,240,190,0.62)");
    rg.addColorStop(0.72, "rgba(180,220,255,0.26)");
    rg.addColorStop(0.86, "rgba(80,155,220,0.10)");
    rg.addColorStop(1.00, "rgba(0,0,0,0)");

    ctx.fillStyle = rg;
    ctx.beginPath();
    // bottom half: 0 -> PI (in scaled space, positive y is up after scale? Actually scale y positive, arc 0->PI is bottom half (positive y). Good.
    ctx.arc(0, 0, outer, 0, Math.PI);
    ctx.arc(0, 0, inner, Math.PI, 0, true);
    ctx.closePath();
    ctx.fill("evenodd");

    // front brightness boost — stronger beaming in foreground
    const dop = ctx.createLinearGradient(-outer, 0, outer, 0);
    dop.addColorStop(0.00, "rgba(255,245,220,0.00)");
    dop.addColorStop(0.28, "rgba(255,230,160,0.10)");
    dop.addColorStop(0.40, "rgba(255,255,255,0.22)");
    dop.addColorStop(0.52, "rgba(255,255,255,0.08)");
    dop.addColorStop(0.68, "rgba(90,170,255,0.10)");
    dop.addColorStop(1.00, "rgba(0,0,0,0)");
    ctx.globalCompositeOperation = "screen";
    ctx.fillStyle = dop;
    ctx.beginPath();
    ctx.arc(0, 0, outer, 0, Math.PI);
    ctx.arc(0, 0, inner, Math.PI, 0, true);
    ctx.closePath();
    ctx.fill("evenodd");
    ctx.globalCompositeOperation = "source-over";

    // moving bright knot in front
    const knotA = (t * 0.38) % (Math.PI * 2);
    if (knotA >= 0 && knotA <= Math.PI) {
      const kr = (inner + outer) * 0.5;
      const kx = Math.cos(knotA) * kr;
      const ky = Math.sin(knotA) * kr;
      const kg = ctx.createRadialGradient(kx, ky, 0, kx, ky, BH_R * 0.52);
      kg.addColorStop(0, "rgba(255,255,255,0.62)");
      kg.addColorStop(0.26, "rgba(255,225,160,0.44)");
      kg.addColorStop(0.58, "rgba(255,150,70,0.16)");
      kg.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = kg;
      ctx.beginPath();
      ctx.arc(kx, ky, BH_R * 0.52, 0, Math.PI * 2);
      ctx.fill();
    }

    ctx.restore();
    ctx.restore();
  }

  function drawFrame(tSec) {
    drawBackground(tSec);
    drawStars(tSec);
    drawDiskBack(tSec);
    drawPhotonRingAndHorizon(tSec);
    drawDiskFront(tSec);

    // ultra-subtle vignette in canvas (reinforces CSS vignette, helps horizon pop on bright screens)
    const vg = ctx.createRadialGradient(cx, cy, Math.min(w, h) * 0.42, cx, cy, Math.max(w, h) * 0.88);
    vg.addColorStop(0, "rgba(0,0,0,0)");
    vg.addColorStop(1, "rgba(0,0,0,0.42)");
    ctx.fillStyle = vg;
    ctx.fillRect(0, 0, w, h);
  }

  function drawStatic() {
    drawFrame(0.6);
  }

  function loop(now) {
    const t = (now - t0) * 0.001;
    drawFrame(t);
    raf = requestAnimationFrame(loop);
  }

  // --- lifecycle ---
  function start() {
    cancelAnimationFrame(raf);
    raf = 0;
    if (mReduced.matches) { drawStatic(); return; }
    if (document.visibilityState === "hidden") { drawStatic(); return; }
    t0 = performance.now();
    raf = requestAnimationFrame(loop);
  }
  function stop() { cancelAnimationFrame(raf); raf = 0; }

  // input: parallax
  window.addEventListener("mousemove", (e) => {
    const nx = (e.clientX / w - 0.5);
    const ny = (e.clientY / h - 0.5);
    tmx = nx; tmy = ny;
  }, { passive: true });

  window.addEventListener("deviceorientation", (e) => {
    if (e.beta == null || e.gamma == null) return;
    tmx = Math.max(-1, Math.min(1, e.gamma / 30));
    tmy = Math.max(-1, Math.min(1, e.beta / 30 - 0.5));
  }, { passive: true });

  // touch parallax
  window.addEventListener("touchmove", (e) => {
    if (!e.touches[0]) return;
    tmx = (e.touches[0].clientX / w - 0.5);
    tmy = (e.touches[0].clientY / h - 0.5);
  }, { passive: true });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") stop();
    else start();
  });
  if (typeof mReduced.addEventListener === "function") {
    mReduced.addEventListener("change", () => { resize(); start(); });
  } else if (typeof mReduced.addListener === "function") {
    mReduced.addListener(() => { resize(); start(); });
  }

  // scroll-based micro parallax for the canvas itself (moves BH slightly)
  let ticking = false;
  window.addEventListener("scroll", () => {
    if (mReduced.matches || ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      ticking = false;
      const y = window.scrollY || 0;
      const off = Math.min(18, y * 0.06);
      // nudge cy visually via CSS translate (cheaper than recalc) — keep canvas transform out of draw loop
      canvas.style.transform = `translate3d(0,${off * 0.35}px,0)`;
    });
  }, { passive: true });

  // resize observer + fallback
  const ro = (typeof ResizeObserver !== "undefined") ? new ResizeObserver(() => resize()) : null;
  if (ro) ro.observe(document.documentElement);
  window.addEventListener("resize", resize, { passive: true });

  // initial
  // wait for CSS/layout
  if (document.readyState === "complete") resize(), start();
  else window.addEventListener("load", () => { resize(); start(); }, { once: true });
  // also kick asap
  requestAnimationFrame(() => { if (w === 0) resize(); });
})();
