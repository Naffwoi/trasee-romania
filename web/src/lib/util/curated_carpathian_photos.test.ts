import { describe, expect, it } from "vitest";
import {
    isPlaceholderPhotoName,
    resolveCuratedCarpathianPhoto,
} from "./curated_carpathian_photos";
import { isValidTrailDate } from "./format_util";

describe("curated Carpathian photos & zero-date guards", () => {
    it("rejects Go zero dates and accepts modern trail dates", () => {
        expect(isValidTrailDate(null)).toBe(false);
        expect(isValidTrailDate("")).toBe(false);
        expect(isValidTrailDate("0001-01-01 00:00:00.000Z")).toBe(false);
        expect(isValidTrailDate("1970-01-01T00:00:00Z")).toBe(false);
        expect(isValidTrailDate("2026-11-17T18:10:48Z")).toBe(true);
    });

    it("detects route placeholder SVGs and resolves Carpathian photography", () => {
        expect(isPlaceholderPhotoName("")).toBe(true);
        expect(isPlaceholderPhotoName("wanderer_route_placeholder_xyz.svg")).toBe(true);
        expect(isPlaceholderPhotoName("real_summit_photo.jpg")).toBe(false);

        expect(
            resolveCuratedCarpathianPhoto({
                name: "Timișu de Sus - Cascada Tamina - Stâna sub Piatra Mare",
                location: "DN1 (Timișu de Sus)",
            })?.assetPath,
        ).toBe("/images/carpathians/cascada_tamina.jpg");

        expect(
            resolveCuratedCarpathianPhoto({
                name: "Predeal - Fetifoiu - La Șipote",
                location: "Predeal",
            })?.assetPath,
        ).toBe("/images/carpathians/predeal_clabucet.jpg");
    });
});
