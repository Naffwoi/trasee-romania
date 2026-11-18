import type { LocationSearchResult } from "#lib/stores/search_store.ts";

const SAFE_FA_ICON_SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export function isSafeFontAwesomeSlug(value: string | undefined | null): value is string {
	return (
		typeof value === "string" &&
		value.length > 0 &&
		value.length <= 64 &&
		SAFE_FA_ICON_SLUG_RE.test(value)
	);
}

export function getIconForLocation(l: LocationSearchResult): string {
	if (l.category === "aerialway") {
		return "cable-car";
	} else if (l.category === "amenity") {
		switch (l.type) {
			case "bar":
				return "martini-glass";
			case "pub":
			case "biergarten":
				return "beer-mug-empty";
			case "cafe":
				return "mug-saucer";
			case "ice_cream":
				return "ice-cream";
			case "fast_food":
				return "burger";
			case "restaurant":
			case "food_court":
				return "utensils";
			case "ferry_terminal":
				return "ferry";
			case "bus_station":
				return "bus";
			case "parking":
				return "square-parking";
			case "place_of_worship":
				return "place-of-worship";
		}
	} else if (l.category === "building") {
		switch (l.type) {
			case "hotel":
				return "hotel";
			case "cathedral":
			case "church":
			case "chapel":
				return "church";
			case "mosque":
				return "mosque";
			case "synagogue":
				return "synagogue";
			case "temple":
				return "gopuram";
			case "train_station":
				return "train";
		}
	} else if (l.category === "natural") {
		switch (l.type) {
			case "peak":
				return "mountain";
			case "wood":
				return "tree";
			case "beach":
				return "umbrella-beach";
			case "water":
				return "water";
		}
	} else if (l.category === "leisure") {
		switch (l.type) {
			case "garden":
				return "leaf";
			case "park":
				return "tree";
			case "swimming_area":
			case "swimming_pool":
			case "water_park ":
				return "person-swimming";
		}
	} else if (l.category === "aeroway") {
		return "plane-departure";
	} else if (l.category === "railway") {
		switch (l.type) {
			case "station":
			case "halt":
				return "train";
			case "subway_entrance":
				return "train-subway";
			case "tram_stop":
				return "train-tram";
		}
	} else if (l.category === "tourism") {
		switch (l.type) {
			case "hotel":
				return "hotel";
			case "alpine_hut":
			case "apartment":
			case "chalet":
				return "house-chimney";
			case "guest_house":
			case "motel":
			case "hostel":
				return "bed";
			case "caravan_site":
				return "caravan";
			case "camp_site":
			case "camp_pitch":
				return "campground";
			case "aqaurium":
				return "fish-fins";
			case "artwork":
				return "palette";
			case "viewpoint":
			case "attraction":
				return "eye";
			case "zoo":
				return "hippo";
			case "national_park":
				return "tree";
		}
	} else if (l.category === "place" || l.category === "boundary") {
		switch (l.type) {
			case "city":
				return "city";
			case "town":
			case "village":
			case "hamlet":
				return "building";
		}
	} else if (l.category === "historic") {
		return "eye";
	}
	return "location-dot";
}
