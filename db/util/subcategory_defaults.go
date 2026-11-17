package util

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
)

type defaultSubcategorySeed struct {
	parentCategory string
	name           string
	shortName      string
	badgeIcon      string
	translations   map[string]CategoryTranslation
	aliases        []string
	settings       map[string]any
}

var defaultSubcategories = []defaultSubcategorySeed{
	{
		parentCategory: "Biking",
		name:           "MTB",
		shortName:      "MTB",
		badgeIcon:      "mountain",
		translations: map[string]CategoryTranslation{
			"ro": {Name: "MTB", ShortName: "MTB"},
		},
		settings: map[string]any{"valhalla_profile": "bicycle_mountain"},
	},
	{
		parentCategory: "Biking",
		name:           "Gravel",
		shortName:      "GRVL",
		translations: map[string]CategoryTranslation{
			"ro": {Name: "Gravel", ShortName: "GRVL"},
		},
		settings: map[string]any{"valhalla_profile": "bicycle_cross"},
	},
	{
		parentCategory: "Biking",
		name:           "Touring",
		shortName:      "TOUR",
		aliases:        []string{"Touring Bike", "City Bike"},
		translations:   subcategoryTranslationsWithRo("Touring", "Tourenrad", "Cicloturism", "TOUR", "TUR"),
		settings:       map[string]any{"valhalla_profile": "bicycle_hybrid"},
	},
	{
		parentCategory: "Biking",
		name:           "Road",
		shortName:      "ROAD",
		badgeIcon:      "grip-lines-vertical",
		translations:   subcategoryTranslationsWithRo("Road", "Rennrad", "Șosea", "ROAD", "ȘOS"),
		settings:       map[string]any{"valhalla_profile": "bicycle_road"},
	},
	{
		parentCategory: "Biking",
		name:           "E-Bike",
		shortName:      "EBIKE",
		badgeIcon:      "bolt",
		translations: map[string]CategoryTranslation{
			"ro": {Name: "E-Bike", ShortName: "EBIKE"},
		},
		// Valhalla has no dedicated e-bike costing; Hybrid is the closest
		// general-purpose bike profile.
		settings: map[string]any{"valhalla_profile": "bicycle_hybrid"},
	},
	{
		parentCategory: "Hiking",
		name:           "Winter",
		shortName:      "WINT",
		badgeIcon:      "snowflake",
		aliases:        []string{"Winter Hiking"},
		translations: map[string]CategoryTranslation{
			"de": {Name: "Winterwandern", ShortName: "WINT"},
			"en": {Name: "Winter", ShortName: "WINT"},
			"ro": {Name: "Iarnă", ShortName: "IARN"},
		},
	},
	{
		parentCategory: "Hiking",
		name:           "Alpine",
		shortName:      "ALP",
		badgeIcon:      "mountain",
		aliases:        []string{"Alpine Hiking"},
		translations:   subcategoryTranslationsWithRo("Alpine", "Bergwandern", "Alpin", "ALP", "ALP"),
	},
	{
		parentCategory: "Hiking",
		name:           "Long-distance",
		shortName:      "LONG",
		aliases:        []string{"Long-distance Hiking"},
		translations:   subcategoryTranslationsWithRo("Long-distance", "Fernwandern", "Distanță lungă", "LONG", "LUNG"),
	},
	{
		parentCategory: "Hiking",
		name:           "Snowshoeing",
		shortName:      "SNOW",
		badgeIcon:      "snowflake",
		translations:   subcategoryTranslationsWithRo("Snowshoeing", "Schneeschuhwandern", "Rachete de zăpadă", "SNOW", "ZĂP"),
	},
	{
		parentCategory: "Hiking",
		name:           "Family",
		shortName:      "FAM",
		badgeIcon:      "child",
		aliases:        []string{"Family Hiking"},
		translations:   subcategoryTranslationsWithRo("Family", "Familienwandern", "Familie", "FAM", "FAM"),
	},
	{
		parentCategory: "Hiking",
		name:           "Pilgrimage",
		shortName:      "PILG",
		badgeIcon:      "cross",
		translations:   subcategoryTranslationsWithRo("Pilgrimage", "Pilgern", "Pelerinaj", "PILG", "PEL"),
	},
	{
		parentCategory: "Running",
		name:           "Trail",
		shortName:      "TRAIL",
		aliases:        []string{"Trail Running"},
		translations:   subcategoryTranslationsWithRo("Trail", "Trailrunning", "Alergare montană", "TRAIL", "TRAIL"),
	},
	{
		parentCategory: "Running",
		name:           "Road",
		shortName:      "ROAD",
		badgeIcon:      "grip-lines-vertical",
		aliases:        []string{"Road Running"},
		translations:   subcategoryTranslationsWithRo("Road", "Straßenlauf", "Alergare pe șosea", "ROAD", "ȘOS"),
	},
	{
		parentCategory: "Skiing",
		name:           "Cross-country",
		shortName:      "NORD",
		aliases:        []string{"Cross-country Skiing"},
		translations:   subcategoryTranslationsWithRo("Cross-country", "Langlauf", "Schi fond", "NORD", "FOND"),
	},
	{
		parentCategory: "Skiing",
		name:           "Skating",
		shortName:      "SKATE",
		translations:   subcategoryTranslationsWithRo("Skating", "Skating", "Schi skating", "SKATE", "SKATE"),
	},
	{
		parentCategory: "Skiing",
		name:           "Backcountry",
		shortName:      "BACK",
		aliases:        []string{"Backcountry Skiing"},
		translations:   subcategoryTranslationsWithRo("Backcountry", "Skitour", "Schi de tură", "BACK", "TURĂ"),
	},
}

func subcategoryTranslationsWithRo(en string, de string, ro string, shortName string, roShortName string) map[string]CategoryTranslation {
	return map[string]CategoryTranslation{
		"de": {Name: de, ShortName: shortName},
		"en": {Name: en, ShortName: shortName},
		"ro": {Name: ro, ShortName: roShortName},
	}
}

func SeedDefaultSubcategories(app core.App) error {
	subcategoriesCollection, err := app.FindCollectionByNameOrId("subcategories")
	if err != nil {
		return err
	}
	hasSettingsField := subcategoriesCollection.Fields.GetByName("settings") != nil

	for _, seed := range defaultSubcategories {
		categories, err := app.FindRecordsByFilter(
			"categories",
			"name = {:name}",
			"",
			1,
			0,
			map[string]any{"name": seed.parentCategory},
		)
		if err != nil {
			return err
		}
		if len(categories) == 0 {
			continue
		}
		category := categories[0]

		existing, err := app.FindRecordsByFilter(
			"subcategories",
			"category = {:category}",
			"",
			0,
			0,
			map[string]any{"category": category.Id},
		)
		if err != nil {
			return err
		}
		if existingRecord := findDefaultSubcategory(existing, seed.name, seed.aliases); existingRecord != nil {
			changed, err := applyDefaultSubcategorySeed(existingRecord, seed, hasSettingsField)
			if err != nil {
				return err
			}
			if changed {
				if err := app.Save(existingRecord); err != nil {
					return fmt.Errorf("failed to update seeded subcategory %q: %w", seed.name, err)
				}
			}
			continue
		}

		record := core.NewRecord(subcategoriesCollection)
		record.Set("category", category.Id)
		record.Set("name", seed.name)
		record.Set("short_name", seed.shortName)
		if seed.badgeIcon != "" {
			record.Set("badge_icon", seed.badgeIcon)
		}
		if len(seed.translations) > 0 {
			record.Set("translations", seed.translations)
		}
		if hasSettingsField && len(seed.settings) > 0 {
			record.Set("settings", seed.settings)
		}
		if err := app.Save(record); err != nil {
			return fmt.Errorf("failed to seed subcategory %q: %w", seed.name, err)
		}
	}

	return nil
}

func applyDefaultSubcategorySeed(record *core.Record, seed defaultSubcategorySeed, hasSettingsField bool) (bool, error) {
	changed := false

	if isDefaultSubcategoryAlias(record.GetString("name"), seed.aliases) {
		record.Set("name", seed.name)
		changed = true
	}

	if record.GetString("short_name") == "" && seed.shortName != "" {
		record.Set("short_name", seed.shortName)
		changed = true
	}

	if record.GetString("badge_icon") == "" && seed.badgeIcon != "" {
		record.Set("badge_icon", seed.badgeIcon)
		changed = true
	}

	if len(seed.translations) > 0 {
		currentTranslations, err := ParseCategoryTranslations(record.Get("translations"))
		if err != nil {
			return false, fmt.Errorf("invalid existing translations for subcategory %q: %w", record.GetString("name"), err)
		}

		mergedTranslations, translationsChanged := mergeDefaultSubcategoryTranslations(seed.translations, currentTranslations)
		if translationsChanged {
			record.Set("translations", mergedTranslations)
			changed = true
		}
	}

	// Retroactively backfill `valhalla_profile` onto a pre-existing default
	// subcategory, but only when the key is absent — an operator-set value (or a
	// value written by a previous seeding run) is never overwritten, which also
	// makes a second SeedDefaultSubcategories call a no-op for settings. Settings
	// that are not an object are left alone rather than replaced.
	if hasSettingsField && len(seed.settings) > 0 && !isNonObjectSettings(record.Get("settings")) {
		currentSettings := parseSettingsMap(record.Get("settings"))
		settingsChanged := false
		for key, value := range seed.settings {
			if _, exists := currentSettings[key]; exists {
				continue
			}
			currentSettings[key] = value
			settingsChanged = true
		}
		if settingsChanged {
			record.Set("settings", currentSettings)
			changed = true
		}
	}

	return changed, nil
}

func isDefaultSubcategoryAlias(name string, aliases []string) bool {
	normalizedName := NormalizeCategoryName(name)
	for _, alias := range aliases {
		if normalizedName == NormalizeCategoryName(alias) {
			return true
		}
	}

	return false
}

func mergeDefaultSubcategoryTranslations(staticTranslations map[string]CategoryTranslation, currentTranslations map[string]CategoryTranslation) (map[string]CategoryTranslation, bool) {
	if currentTranslations == nil {
		currentTranslations = map[string]CategoryTranslation{}
	}

	changed := false
	for locale, staticTranslation := range staticTranslations {
		translation := currentTranslations[locale]
		localeChanged := false
		if translation.Name == "" && staticTranslation.Name != "" {
			translation.Name = staticTranslation.Name
			localeChanged = true
		}
		if translation.ShortName == "" && staticTranslation.ShortName != "" {
			translation.ShortName = staticTranslation.ShortName
			localeChanged = true
		}
		if localeChanged {
			changed = true
			currentTranslations[locale] = translation
		}
	}

	return currentTranslations, changed
}

func findDefaultSubcategory(records []*core.Record, name string, aliases []string) *core.Record {
	normalizedName := NormalizeCategoryName(name)
	for _, record := range records {
		if NormalizeCategoryName(record.GetString("name")) == normalizedName {
			return record
		}
	}

	normalizedAliases := map[string]struct{}{}
	for _, alias := range aliases {
		normalizedAliases[NormalizeCategoryName(alias)] = struct{}{}
	}

	for _, record := range records {
		if _, ok := normalizedAliases[NormalizeCategoryName(record.GetString("name"))]; ok {
			return record
		}
	}

	return nil
}
