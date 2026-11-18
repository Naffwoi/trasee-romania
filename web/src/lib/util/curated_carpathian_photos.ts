export interface CuratedCarpathianPhoto {
    assetPath: string;
    caption: string;
    license: string;
}

const TAMINA_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/cascada_tamina.jpg",
    caption: "Canionul Tamina · CC0",
    license: "CC0",
};

const SAPTE_SCARI_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/canionul_7_scari.jpg",
    caption: "Canionul 7 Scări · CC BY 3.0",
    license: "CC BY 3.0",
};

const PIATRA_MARE_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/varful_piatra_mare.jpg",
    caption: "Masivul Piatra Mare · CC BY-SA 3.0",
    license: "CC BY-SA 3.0",
};

const PREDEAL_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/predeal_clabucet.jpg",
    caption: "Predeal – Clăbucet · CC BY 2.0",
    license: "CC BY 2.0",
};

const POSTAVARUL_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/postavarul.jpg",
    caption: "Masivul Postăvarul · CC BY 3.0",
    license: "CC BY 3.0",
};

const CIUCAS_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/varful_ciucas.jpg",
    caption: "Munții Ciucaș · CC BY-SA 3.0",
    license: "CC BY-SA 3.0",
};

const PIATRA_CRAIULUI_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/piatra_craiului.jpg",
    caption: "Piatra Craiului · CC BY 2.0",
    license: "CC BY 2.0",
};

const BUCEGI_PHOTO: CuratedCarpathianPhoto = {
    assetPath: "/images/carpathians/cabana_carpati.jpg",
    caption: "Munții Bucegi – Vf. Omu · CC BY-SA 3.0",
    license: "CC BY-SA 3.0",
};

const CENTROIDS: ReadonlyArray<[number, number, CuratedCarpathianPhoto]> = [
    [45.548, 25.643, TAMINA_PHOTO],
    [45.565, 25.644, SAPTE_SCARI_PHOTO],
    [45.554, 25.647, PIATRA_MARE_PHOTO],
    [45.505, 25.578, PREDEAL_PHOTO],
    [45.569, 25.569, POSTAVARUL_PHOTO],
    [45.522, 25.926, CIUCAS_PHOTO],
    [45.528, 25.217, PIATRA_CRAIULUI_PHOTO],
    [45.446, 25.456, BUCEGI_PHOTO],
];

export function isPlaceholderPhotoName(name?: string | null): boolean {
    if (!name) return true;
    const trimmed = name.trim();
    return trimmed.length === 0 || trimmed.includes("wanderer_route_placeholder");
}

function foldDiacritics(input: string): string {
    return input
        .toLowerCase()
        .replaceAll("ă", "a")
        .replaceAll("â", "a")
        .replaceAll("î", "i")
        .replaceAll("ș", "s")
        .replaceAll("ş", "s")
        .replaceAll("ț", "t")
        .replaceAll("ţ", "t");
}

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R = 6371;
    const dLat = ((lat2 - lat1) * Math.PI) / 180;
    const dLon = ((lon2 - lon1) * Math.PI) / 180;
    const a =
        Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos((lat1 * Math.PI) / 180) *
            Math.cos((lat2 * Math.PI) / 180) *
            Math.sin(dLon / 2) *
            Math.sin(dLon / 2);
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function resolveCuratedCarpathianPhoto(opts: {
    name: string;
    location?: string | null;
    lat?: number | null;
    lon?: number | null;
}): CuratedCarpathianPhoto | null {
    const haystack = foldDiacritics(`${opts.name} ${opts.location ?? ""}`);

    if (haystack.includes("tamina")) return TAMINA_PHOTO;
    if (haystack.includes("7 scari") || haystack.includes("sapte scari")) return SAPTE_SCARI_PHOTO;
    if (
        haystack.includes("piatra mare") ||
        haystack.includes("dambu morii") ||
        haystack.includes("timisu") ||
        haystack.includes("familiar")
    ) {
        return PIATRA_MARE_PHOTO;
    }
    if (
        haystack.includes("predeal") ||
        haystack.includes("clabucet") ||
        haystack.includes("fetifoiu") ||
        haystack.includes("sipote") ||
        haystack.includes("susai") ||
        haystack.includes("garbova")
    ) {
        return PREDEAL_PHOTO;
    }
    if (
        haystack.includes("postavaru") ||
        haystack.includes("poiana brasov") ||
        haystack.includes("tampa") ||
        haystack.includes("rasnov") ||
        haystack.includes("cristian")
    ) {
        return POSTAVARUL_PHOTO;
    }
    if (
        haystack.includes("ciucas") ||
        haystack.includes("bratocea") ||
        haystack.includes("muntele rosu") ||
        haystack.includes("cheia") ||
        haystack.includes("tigailor")
    ) {
        return CIUCAS_PHOTO;
    }
    if (
        haystack.includes("piatra craiului") ||
        haystack.includes("zarnesti") ||
        haystack.includes("prapastiile") ||
        haystack.includes("curmatura") ||
        haystack.includes("ascutit") ||
        haystack.includes("magura")
    ) {
        return PIATRA_CRAIULUI_PHOTO;
    }
    if (
        haystack.includes("bucegi") ||
        haystack.includes("omu") ||
        haystack.includes("caraiman") ||
        haystack.includes("babele") ||
        haystack.includes("busteni") ||
        haystack.includes("sinaia") ||
        haystack.includes("diham") ||
        haystack.includes("malaiesti")
    ) {
        return BUCEGI_PHOTO;
    }

    if (
        opts.lat !== null &&
        opts.lat !== undefined &&
        opts.lon !== null &&
        opts.lon !== undefined &&
        Number.isFinite(opts.lat) &&
        Number.isFinite(opts.lon)
    ) {
        let best: CuratedCarpathianPhoto | null = null;
        let bestKm = 25;
        for (const [cLat, cLon, photo] of CENTROIDS) {
            const dist = haversineKm(opts.lat, opts.lon, cLat, cLon);
            if (dist <= bestKm) {
                bestKm = dist;
                best = photo;
            }
        }
        return best;
    }

    return null;
}
