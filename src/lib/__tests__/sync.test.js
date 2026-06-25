import { describe, it, expect } from "vitest";
import { dataUpdatedAt, resolveSync } from "../sync.js";

describe("dataUpdatedAt", () => {
  it("parses an ISO timestamp to a number", () => {
    expect(dataUpdatedAt({ updatedAt: "2026-06-24T10:00:00.000Z" })).toBe(Date.parse("2026-06-24T10:00:00.000Z"));
  });

  it("returns 0 for missing/invalid timestamps", () => {
    expect(dataUpdatedAt(null)).toBe(0);
    expect(dataUpdatedAt({})).toBe(0);
    expect(dataUpdatedAt({ updatedAt: "nonsense" })).toBe(0);
  });
});

describe("resolveSync", () => {
  const older = { updatedAt: "2026-06-24T10:00:00.000Z" };
  const newer = { updatedAt: "2026-06-24T11:00:00.000Z" };

  it("uses local when there is no cloud copy", () => {
    expect(resolveSync(older, null)).toEqual({ use: "local", data: older });
  });

  it("uses cloud when there is no local copy", () => {
    expect(resolveSync(null, older)).toEqual({ use: "cloud", data: older });
  });

  it("uses the newer copy", () => {
    expect(resolveSync(older, newer)).toEqual({ use: "cloud", data: newer });
    expect(resolveSync(newer, older)).toEqual({ use: "local", data: newer });
  });

  it("keeps local on a tie", () => {
    expect(resolveSync(older, { updatedAt: older.updatedAt }).use).toBe("local");
  });
});
