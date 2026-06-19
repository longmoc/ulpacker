export const PIE_COLORS = ["#1d4ed8", "#059669", "#d97706", "#dc2626", "#7c3aed", "#0e7490", "#a16207"];

export function buildPieSegments(categoryRows) {
  const total = categoryRows.reduce((sum, row) => sum + row.weight, 0);
  if (!total) return [];

  let cursor = 0;
  return categoryRows.map((row, index) => {
    const value = (row.weight / total) * 100;
    const from = cursor;
    const to = cursor + value;
    cursor = to;
    return {
      ...row,
      color: PIE_COLORS[index % PIE_COLORS.length],
      from,
      to,
      percent: value
    };
  });
}

export function polarToCartesian(cx, cy, r, angleDeg) {
  const angle = (angleDeg - 90) * (Math.PI / 180);
  return {
    x: cx + r * Math.cos(angle),
    y: cy + r * Math.sin(angle)
  };
}

export function describeDonutArc(cx, cy, outerR, innerR, startDeg, endDeg) {
  const clampedEnd = Math.max(startDeg + 0.01, endDeg);
  const outerStart = polarToCartesian(cx, cy, outerR, startDeg);
  const outerEnd = polarToCartesian(cx, cy, outerR, clampedEnd);
  const innerStart = polarToCartesian(cx, cy, innerR, clampedEnd);
  const innerEnd = polarToCartesian(cx, cy, innerR, startDeg);
  const largeArc = clampedEnd - startDeg > 180 ? 1 : 0;

  return [
    `M ${outerStart.x} ${outerStart.y}`,
    `A ${outerR} ${outerR} 0 ${largeArc} 1 ${outerEnd.x} ${outerEnd.y}`,
    `L ${innerStart.x} ${innerStart.y}`,
    `A ${innerR} ${innerR} 0 ${largeArc} 0 ${innerEnd.x} ${innerEnd.y}`,
    "Z"
  ].join(" ");
}
