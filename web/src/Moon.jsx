// A waxing-gibbous moon drawn as the real near side: maria in their actual places, Tycho's ray system,
// Copernicus and Kepler, faint small craters, mottled highlands, and a soft terminator.

// [cx, cy, rx, ry, rotation] in a 200×200 box
const MARIA = [
  [52, 98, 30, 46, -8], // Oceanus Procellarum
  [38, 120, 12, 16, 15],
  [72, 60, 28, 19, -12], // Mare Imbrium
  [60, 48, 12, 8, 0],
  [102, 36, 42, 6, -4], // Mare Frigoris
  [113, 63, 14, 13, 0], // Mare Serenitatis
  [127, 89, 19, 15, 20], // Mare Tranquillitatis
  [140, 78, 8, 7, 0],
  [161, 72, 10, 8, 10], // Mare Crisium
  [151, 110, 11, 17, -10], // Mare Fecunditatis
  [134, 126, 8, 8, 0], // Mare Nectaris
  [86, 130, 17, 12, 10], // Mare Nubium
  [70, 118, 9, 6, 30],
  [52, 131, 9, 9, 0], // Mare Humorum
  [104, 102, 9, 7, 0], // Sinus Medii / Mare Vaporum
];

// [cx, cy, r, brightness] — named craters first, then a seeded scatter of small ones
const NAMED = [
  [95, 166, 4.2, 1], // Tycho
  [76, 92, 4.5, 0.85], // Copernicus
  [55, 88, 2.6, 0.8], // Kepler
  [46, 66, 2.2, 0.95], // Aristarchus
  [118, 150, 3.4, 0.5], // a highland crater near Maurolycus
];

function rng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SMALL_CRATERS = (() => {
  const rand = rng(1969);
  const out = [];
  while (out.length < 90) {
    const x = 100 + (rand() * 2 - 1) * 92;
    const y = 100 + (rand() * 2 - 1) * 92;
    if (Math.hypot(x - 100, y - 100) > 90) continue;
    // the southern highlands are far more cratered than the maria
    if (y < 120 && rand() < 0.6) continue;
    out.push([x, y, 0.6 + rand() ** 2.5 * 3, 0.2 + rand() * 0.35]);
  }
  return out;
})();

// Ray systems: long soft streaks from Tycho, shorter ones from Copernicus and Kepler
function rays(cx, cy, count, minLen, spread, seed) {
  const rand = rng(seed);
  return Array.from({ length: count }, () => {
    const a = rand() * Math.PI * 2;
    const len = minLen + rand() * spread;
    const w = 0.025 + rand() * 0.03; // half-angle of the taper
    const x1 = cx + Math.cos(a - w) * len;
    const y1 = cy + Math.sin(a - w) * len;
    const x2 = cx + Math.cos(a + w) * len;
    const y2 = cy + Math.sin(a + w) * len;
    return `M${cx} ${cy} L${x1.toFixed(1)} ${y1.toFixed(1)} L${x2.toFixed(1)} ${y2.toFixed(1)} Z`;
  }).join(" ");
}
const RAYS = [rays(95, 166, 20, 25, 50, 4), rays(76, 92, 12, 10, 20, 9), rays(55, 88, 8, 8, 18, 13)].join(" ");

export default function Moon() {
  const ellipses = (scale = 1) =>
    MARIA.map(([cx, cy, rx, ry, rot], i) => (
      <ellipse key={i} cx={cx} cy={cy} rx={rx * scale} ry={ry * scale} transform={`rotate(${rot} ${cx} ${cy})`} />
    ));

  return (
    <svg viewBox="0 0 200 200" aria-hidden="true">
      <defs>
        <clipPath id="moon-disc">
          <circle cx="100" cy="100" r="98" />
        </clipPath>
        <radialGradient id="moon-base" cx="42%" cy="42%" r="62%">
          <stop offset="0%" stopColor="#efebe4" />
          <stop offset="70%" stopColor="#ddd8d0" />
          <stop offset="100%" stopColor="#b3aea9" />
        </radialGradient>
        <linearGradient id="moon-terminator" x1="0" y1="0" x2="1" y2="0.15">
          <stop offset="0.6" stopColor="#05030a" stopOpacity="0" />
          <stop offset="0.84" stopColor="#05030a" stopOpacity="0.5" />
          <stop offset="1" stopColor="#05030a" stopOpacity="0.9" />
        </linearGradient>
        <radialGradient id="crater-floor">
          <stop offset="0%" stopColor="#4a4650" stopOpacity="0.3" />
          <stop offset="80%" stopColor="#4a4650" stopOpacity="0.12" />
          <stop offset="100%" stopColor="#4a4650" stopOpacity="0" />
        </radialGradient>
        <radialGradient id="ray-halo">
          <stop offset="0%" stopColor="#fffdf8" stopOpacity="0.55" />
          <stop offset="100%" stopColor="#fffdf8" stopOpacity="0" />
        </radialGradient>

        {/* lobed, irregular mare outlines */}
        <filter id="moon-ragged" x="-20%" y="-20%" width="140%" height="140%">
          <feTurbulence type="fractalNoise" baseFrequency="0.05" numOctaves="5" seed="3" result="n" />
          <feDisplacementMap in="SourceGraphic" in2="n" scale="20" xChannelSelector="R" yChannelSelector="G" />
          <feGaussianBlur stdDeviation="1.6" />
        </filter>
        <filter id="moon-ragged-soft" x="-20%" y="-20%" width="140%" height="140%">
          <feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="4" seed="5" result="n" />
          <feDisplacementMap in="SourceGraphic" in2="n" scale="26" xChannelSelector="R" yChannelSelector="G" />
          <feGaussianBlur stdDeviation="4" />
        </filter>
        <mask id="maria-core">
          <g fill="#fff" filter="url(#moon-ragged)">{ellipses(0.92)}</g>
        </mask>
        <mask id="maria-halo">
          <g fill="#fff" filter="url(#moon-ragged-soft)">{ellipses(1.12)}</g>
        </mask>

        {/* mottling inside the maria: lava flows of slightly different ages */}
        <filter id="maria-tone">
          <feTurbulence type="fractalNoise" baseFrequency="0.07" numOctaves="4" seed="21" />
          <feColorMatrix values="0 0 0 0 0.34  0 0 0 0 0.33  0 0 0 0 0.37  0 0 0 1.8 -0.55" />
        </filter>
        {/* bright and dark patches across the highlands */}
        <filter id="moon-mottle">
          <feTurbulence type="fractalNoise" baseFrequency="0.03" numOctaves="5" seed="12" />
          <feColorMatrix values="0 0 0 0 0.3  0 0 0 0 0.29  0 0 0 0 0.32  0 0 0 1.5 -0.6" />
        </filter>
        <filter id="moon-speckle">
          <feTurbulence type="fractalNoise" baseFrequency="0.22" numOctaves="3" seed="31" />
          <feColorMatrix values="0 0 0 0 1  0 0 0 0 0.99  0 0 0 0 0.96  0 0 0 1.4 -0.78" />
        </filter>
        {/* fine regolith grain */}
        <filter id="moon-grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="8" />
          <feColorMatrix values="0 0 0 0 0.2  0 0 0 0 0.19  0 0 0 0 0.22  0 0 0 0.45 -0.12" />
        </filter>
        <filter id="moon-blur-rays">
          <feGaussianBlur stdDeviation="1.3" />
        </filter>
        <filter id="moon-blur-small">
          <feGaussianBlur stdDeviation="0.5" />
        </filter>
      </defs>

      <g clipPath="url(#moon-disc)">
        <rect width="200" height="200" fill="url(#moon-base)" />
        <rect width="200" height="200" filter="url(#moon-mottle)" />
        <rect width="200" height="200" filter="url(#moon-speckle)" opacity="0.5" />

        {/* maria: a soft darkened fringe, then the mottled dark core */}
        <rect width="200" height="200" fill="#6e6a72" opacity="0.35" mask="url(#maria-halo)" />
        <g mask="url(#maria-core)">
          <rect width="200" height="200" fill="#625d66" opacity="0.72" />
          <rect width="200" height="200" filter="url(#maria-tone)" opacity="0.75" />
        </g>

        {/* ray systems */}
        <path d={RAYS} fill="#fbf8f2" opacity="0.24" filter="url(#moon-blur-rays)" />
        <circle cx="95" cy="166" r="12" fill="url(#ray-halo)" />
        <circle cx="76" cy="92" r="8" fill="url(#ray-halo)" opacity="0.6" />

        {/* small craters: faint pits, lit on the far rim */}
        <g filter="url(#moon-blur-small)">
          {SMALL_CRATERS.map(([cx, cy, r, b], i) => (
            <g key={i}>
              <circle cx={cx} cy={cy} r={r} fill="url(#crater-floor)" />
              <path d={`M${cx} ${cy - r} A${r} ${r} 0 0 1 ${cx} ${cy + r}`} fill="none" stroke="#fffdf8" strokeOpacity={b} strokeWidth={r * 0.3} />
            </g>
          ))}
        </g>

        {/* named craters: crisper, with bright floors */}
        {NAMED.map(([cx, cy, r, b], i) => (
          <g key={i}>
            <circle cx={cx} cy={cy} r={r} fill="url(#crater-floor)" />
            <path d={`M${cx} ${cy - r} A${r} ${r} 0 0 1 ${cx} ${cy + r}`} fill="none" stroke="#fffdf8" strokeOpacity={b * 0.35} strokeWidth={r * 0.3} filter="url(#moon-blur-small)" />
            <path d={`M${cx} ${cy + r} A${r} ${r} 0 0 1 ${cx} ${cy - r}`} fill="none" stroke="#2f2b35" strokeOpacity="0.18" strokeWidth={r * 0.2} filter="url(#moon-blur-small)" />
            <circle cx={cx} cy={cy} r={r * 0.6} fill="#fffdf8" opacity={b * 0.55} filter="url(#moon-blur-small)" />
          </g>
        ))}

        <rect width="200" height="200" filter="url(#moon-grain)" />
        <rect width="200" height="200" fill="url(#moon-terminator)" />
      </g>
    </svg>
  );
}
