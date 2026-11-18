import { describe, expect, it } from "vitest";
import { toDraft } from "#lib/util/trail_search_draft.ts";
import { buildTrailTrainFilterClause } from "./trail_store";

describe("Cu trenul (train_accessible) Web filter", () => {
	it("emits AND train_accessible = true only when trainAccessible is enabled and preserves it across drafts", () => {
		expect(buildTrailTrainFilterClause(undefined)).toBe("");
		expect(buildTrailTrainFilterClause(false)).toBe("");
		expect(buildTrailTrainFilterClause(true)).toBe(" AND train_accessible = true");

		const draft = toDraft({
			q: "",
			category: [],
			subcategory: [],
			tags: [],
			difficulty: [0, 1, 2],
			near: { radius: 2000 },
			distanceMin: 0,
			distanceMax: 100000,
			distanceLimit: 100000,
			elevationGainMin: 0,
			elevationGainMax: 5000,
			elevationGainLimit: 5000,
			elevationLossMin: 0,
			elevationLossMax: 5000,
			elevationLossLimit: 5000,
			trainAccessible: true,
			sort: "created",
			sortOrder: "-",
		});
		expect(draft.trainAccessible).toBe(true);
	});
});
