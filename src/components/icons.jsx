import React from "react";

// Shared line icons so the Packs and Trips views stay visually identical.
const base = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round",
  strokeLinejoin: "round",
  "aria-hidden": "true"
};

export function TrashIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M3 6h18" />
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
      <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      <path d="M10 11v6" />
      <path d="M14 11v6" />
    </svg>
  );
}

export function ImageIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <circle cx="9" cy="9" r="2" />
      <path d="m21 15-4.5-4.5L5 22" />
    </svg>
  );
}

export function PencilIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  );
}

// --- Trip stat icons ---

export function PinIcon({ size = 16 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z" />
      <circle cx="12" cy="10" r="3" />
    </svg>
  );
}

export function TrendUpIcon({ size = 16 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M12 19V5" />
      <path d="m5 12 7-7 7 7" />
    </svg>
  );
}

export function TrendDownIcon({ size = 16 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M12 5v14" />
      <path d="m19 12-7 7-7-7" />
    </svg>
  );
}

export function PeakIcon({ size = 16 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="m3 20 6.5-11 4 6 2.5-4L21 20Z" />
    </svg>
  );
}

export function ChevronIcon({ size = 14, open = false }) {
  return (
    <svg
      {...base}
      width={size}
      height={size}
      style={{ transform: open ? "rotate(180deg)" : "none", transition: "transform 0.12s ease" }}
    >
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

export function WhistleIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <circle cx="8.5" cy="14" r="5.5" />
      <path d="M13.5 10.5H20a1 1 0 0 1 1 1v1.5a1 1 0 0 1-1 1h-1.5" />
      <path d="M8.5 8.5V5.5" />
    </svg>
  );
}

export function FlagIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M5 21V4" />
      <path d="M5 4h11l-2.2 4L16 12H5" />
    </svg>
  );
}

export function LinkIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M9.5 13.5a4 4 0 0 0 5.5 0l2.5-2.5a4 4 0 0 0-5.5-5.5l-1.2 1.2" />
      <path d="M14.5 10.5a4 4 0 0 0-5.5 0L6.5 13a4 4 0 0 0 5.5 5.5l1.2-1.2" />
    </svg>
  );
}

export function TargetIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <circle cx="12" cy="12" r="7" />
      <path d="M12 2v3M12 19v3M2 12h3M19 12h3" />
      <circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

export function FileIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M15 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8Z" />
      <path d="M15 3v5h5" />
    </svg>
  );
}

export function DownloadIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M12 3v10" />
      <path d="m8 9 4 4 4-4" />
      <path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
    </svg>
  );
}

export function UploadIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M12 13V3" />
      <path d="m8 7 4-4 4 4" />
      <path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
    </svg>
  );
}

export function NavigationIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M3 11 22 2l-9 19-2-8-8-2Z" />
    </svg>
  );
}

export function MaximizeIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M8 3H5a2 2 0 0 0-2 2v3" />
      <path d="M16 3h3a2 2 0 0 1 2 2v3" />
      <path d="M16 21h3a2 2 0 0 0 2-2v-3" />
      <path d="M8 21H5a2 2 0 0 1-2-2v-3" />
    </svg>
  );
}

export function MinimizeIcon({ size = 15 }) {
  return (
    <svg {...base} width={size} height={size}>
      <path d="M8 3v3a2 2 0 0 1-2 2H3" />
      <path d="M21 8h-3a2 2 0 0 1-2-2V3" />
      <path d="M16 21v-3a2 2 0 0 1 2-2h3" />
      <path d="M3 16h3a2 2 0 0 1 2 2v3" />
    </svg>
  );
}

export function ClockIcon({ size = 16 }) {
  return (
    <svg {...base} width={size} height={size}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </svg>
  );
}
