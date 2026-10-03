// Night graveyard behind the app: ruined abbey, dead trees, leaning graves, an iron fence and crows.
// Everything is generated once at module load; trees use a seeded RNG so they look the same every visit.

function rng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Recursive dead tree; returns one path string per branch depth so trunks can be drawn thicker than twigs.
function tree(x, y, len, seed, depth = 6) {
  const rand = rng(seed);
  const layers = Array.from({ length: depth + 1 }, () => []);
  (function grow(x1, y1, angle, l, d) {
    const x2 = x1 + Math.cos(angle) * l;
    const y2 = y1 + Math.sin(angle) * l;
    const bend = (rand() - 0.5) * l * 0.5;
    const cx = (x1 + x2) / 2 + Math.cos(angle + Math.PI / 2) * bend;
    const cy = (y1 + y2) / 2 + Math.sin(angle + Math.PI / 2) * bend;
    layers[depth - d].push(`M${x1.toFixed(1)} ${y1.toFixed(1)} Q${cx.toFixed(1)} ${cy.toFixed(1)} ${x2.toFixed(1)} ${y2.toFixed(1)}`);
    if (d === 0) return;
    const forks = d > 4 ? 2 : 2 + (rand() > 0.5 ? 1 : 0);
    for (let i = 0; i < forks; i++) {
      const spread = (i / (forks - 1) - 0.5) * (0.9 + rand() * 0.5);
      grow(x2, y2, angle + spread + (rand() - 0.5) * 0.35, l * (0.68 + rand() * 0.12), d - 1);
    }
  })(x, y, -Math.PI / 2 + (rand() - 0.5) * 0.2, len, depth);
  return layers.map((segs, i) => ({ d: segs.join(" "), width: Math.max(0.8, (depth - i + 1) * 1.9) }));
}

const TREES = [tree(240, 392, 82, 7), tree(1370, 396, 92, 23), tree(1530, 398, 54, 41, 5), tree(70, 400, 48, 11, 5)];

const lancet = (x, y, w, h) => `M${x} ${y + h} V${y + w * 0.9} Q${x} ${y} ${x + w / 2} ${y - w * 0.15} Q${x + w} ${y} ${x + w} ${y + w * 0.9} V${y + h} Z`;
const WINDOWS = [lancet(783, 182, 14, 36), ...[848, 888, 940, 980].map((x) => lancet(x, 250, 14, 42)), lancet(706, 268, 12, 30)];
const RUIN_HOLES = [lancet(1058, 290, 18, 50)];

const GRAVES = [
  { x: 120, h: 40, w: 24, tilt: -6 },
  { x: 175, h: 30, w: 20, tilt: 4 },
  { x: 420, h: 46, w: 26, tilt: -3 },
  { x: 500, h: 32, w: 22, tilt: 8 },
  { x: 1170, h: 42, w: 24, tilt: 5 },
  { x: 1240, h: 30, w: 20, tilt: -7 },
  { x: 1455, h: 38, w: 24, tilt: 3 },
];
const grave = ({ x, h, w }) => `M${x} 412 V${412 - h + w / 2} A${w / 2} ${w / 2} 0 0 1 ${x + w} ${412 - h + w / 2} V412 Z`;

function fence(from, to) {
  const bars = [];
  for (let x = from; x <= to; x += 16) bars.push(`M${x} 420 V372 M${x - 3} 374 L${x} 364 L${x + 3} 374 Z`);
  return `${bars.join(" ")} M${from} 380 H${to} M${from} 408 H${to}`;
}
const FENCE = fence(0, 360) + " " + fence(1250, 1600);

const CROWS = [
  { x: 560, y: 70, s: 1 },
  { x: 610, y: 96, s: 0.7 },
  { x: 1080, y: 52, s: 0.85 },
  { x: 1130, y: 82, s: 0.6 },
];

export default function GothicScene() {
  return (
    <svg className="scene" viewBox="0 0 1600 420" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
      {/* far hills */}
      <path className="hills" d="M0 300 Q200 255 400 292 T800 282 T1200 292 T1600 268 V420 H0 Z" />
      {/* ruined abbey: chapel, bell tower with spire, nave, broken wall */}
      <g className="abbey">
        <path d="M680 340 V262 L720 222 L760 262 V340 Z" />
        <path d="M760 340 V160 L790 70 L820 160 V340 Z" />
        <path d="M820 340 V236 L920 176 L1020 236 V340 Z" />
        <path d="M1020 340 V244 L1036 252 L1048 238 L1062 262 L1078 248 L1094 272 L1110 258 L1124 280 V340 Z" />
        <path className="sky-hole" d={RUIN_HOLES.join(" ")} />
        <path className="glass" d={WINDOWS.join(" ")} />
        <circle className="glass" cx="920" cy="212" r="10" />
      </g>
      <path className="ground-mid" d="M0 336 Q300 320 700 338 T1600 330 V420 H0 Z" />
      {/* trees */}
      <g className="trees">
        {TREES.flatMap((t, i) => t.map((b, j) => <path key={`${i}-${j}`} d={b.d} strokeWidth={b.width} />))}
      </g>
      {/* graves */}
      <g className="graves">
        {GRAVES.map((g) => (
          <path key={g.x} d={grave(g)} transform={`rotate(${g.tilt} ${g.x + g.w / 2} 412)`} />
        ))}
      </g>
      <path className="ground-front" d="M0 404 Q400 392 800 402 T1600 398 V420 H0 Z" />
      <path className="fence" d={FENCE} />
      {/* crows */}
      <g className="crows">
        {CROWS.map((c, i) => (
          <g key={i} transform={`translate(${c.x} ${c.y}) scale(${c.s})`}>
            <path className="crow" style={{ "--i": i }} d="M-14 0 Q-7 -8 0 0 Q7 -8 14 0 Q7 -4 0 2 Q-7 -4 -14 0 Z" />
          </g>
        ))}
      </g>
    </svg>
  );
}
