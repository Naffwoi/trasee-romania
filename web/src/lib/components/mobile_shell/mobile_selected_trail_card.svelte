<script lang="ts">
    import emptyStateTrailDark from "#lib/assets/svgs/empty_states/empty_state_trail_dark.svg";
    import emptyStateTrailLight from "#lib/assets/svgs/empty_states/empty_state_trail_light.svg";
    import type { Trail } from "#lib/models/trail.ts";
    import { theme } from "#lib/stores/theme_store.ts";
    import { handleFromRecordWithIRI } from "#lib/util/activitypub_util.ts";
    import {
        displayCategoryName,
        displayTrailCategoryBadgeIcon,
        displayTrailCategoryIcon,
    } from "#lib/util/category_util.ts";
    import {
        isPlaceholderPhotoName,
        resolveCuratedCarpathianPhoto,
    } from "#lib/util/curated_carpathian_photos.ts";
    import { getFileURL, isVideoURL } from "#lib/util/file_util.ts";
    import {
        formatDistance,
        formatElevation,
        formatTimeHHMM,
        isValidTrailDate,
        trailDisplayDuration,
    } from "#lib/util/format_util.ts";
    import { _, locale } from "svelte-i18n";
    import StatChip from "./stat_chip.svelte";

    interface Props {
        trail: Trail;
        ondismiss: () => void;
        ongroup?: (trail: Trail) => void;
    }

    let { trail, ondismiss, ongroup }: Props = $props();

    const rawThumbName = $derived(
        trail.photos?.length
            ? (trail.photos.at(trail.thumbnail ?? 0) ?? trail.photos[0])
            : null,
    );

    const curatedPhoto = $derived(
        isPlaceholderPhotoName(rawThumbName)
            ? resolveCuratedCarpathianPhoto({
                  name: trail.name,
                  location: trail.location,
                  lat: trail.lat,
                  lon: trail.lon,
              })
            : null,
    );

    const thumbnail = $derived(
        rawThumbName && !isPlaceholderPhotoName(rawThumbName)
            ? getFileURL(trail, rawThumbName, "600x0")
            : curatedPhoto?.assetPath ??
              ($theme === "light" ? emptyStateTrailLight : emptyStateTrailDark),
    );

    const formattedDate = $derived.by(() => {
        const raw = trail.date || trail.created;
        if (!isValidTrailDate(raw)) return "";
        const parsed = new Date(raw as string | number | Date);
        return parsed.toLocaleDateString($locale ?? undefined, {
            month: "short",
            day: "numeric",
            year: "numeric",
            timeZone: "UTC",
        });
    });

    const authorLabel = $derived.by(() => {
        if (!trail.expand?.author?.preferred_username) return "";
        const name = trail.expand.author.preferred_username;
        const domain =
            !trail.expand.author.is_local && trail.expand.author.domain
                ? `@${trail.expand.author.domain}`
                : "";
        return `${name}${domain}`;
    });

    const trailHandle = $derived.by(() => {
        try {
            if (trail.expand?.author?.preferred_username) {
                return handleFromRecordWithIRI(trail);
            }
        } catch {
            // fallback below
        }
        const user = trail.author || trail.expand?.author?.preferred_username || "romania";
        return user.startsWith("@")
            ? user
            : `@${user}${trail.domain ? `@${trail.domain}` : ""}`;
    });

    const detailHref = $derived(`/map/trail/${trailHandle}/${trail.id}`);
    const navigateHref = $derived(`/map/trail/${trailHandle}/${trail.id}/navigate`);
</script>

<article
    aria-label={trail.name}
    class="mobile-selected-trail-card rounded-2xl bg-menu-background text-content border border-input-border/60 shadow-[0_8px_28px_rgba(0,0,0,0.2)] p-3 flex gap-3 items-start"
>
    <a
        href={detailHref}
        aria-label={trail.name}
        class="w-[90px] h-[90px] rounded-xl overflow-hidden shrink-0 bg-input-background flex items-center justify-center focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
    >
        {#if isVideoURL(thumbnail)}
            <!-- svelte-ignore a11y_media_has_caption -->
            <video class="w-full h-full object-cover" autoplay muted loop src={thumbnail}></video>
        {:else}
            <img class="w-full h-full object-cover" src={thumbnail} alt="" />
        {/if}
    </a>

    <div class="flex-1 min-w-0">
        <div class="flex items-start gap-2">
            <a
                href={detailHref}
                class="font-bold text-[15px] leading-snug line-clamp-2 flex-1 wrap-anywhere text-content hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734] rounded"
            >
                {trail.name}
            </a>
            <div class="flex items-center gap-1 shrink-0">
                {#if trail.public}
                    <span
                        class="w-6 h-6 rounded-full bg-content/[0.06] flex items-center justify-center text-content/70 text-[11px]"
                        title={$_("public")}
                    >
                        <i class="fa fa-globe" aria-hidden="true"></i>
                    </span>
                {/if}
                <button
                    type="button"
                    aria-label={$_("close")}
                    class="w-11 h-11 -mr-1.5 -mt-1.5 rounded-full hover:bg-secondary-hover flex items-center justify-center text-content/70 text-sm cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                    onclick={ondismiss}
                >
                    <span
                        class="w-7 h-7 rounded-full bg-content/[0.06] flex items-center justify-center"
                    >
                        <i class="fa fa-xmark" aria-hidden="true"></i>
                    </span>
                </button>
            </div>
        </div>

        {#if formattedDate || authorLabel}
            <div class="flex items-center gap-1.5 mt-1 text-[11px] text-content/60 min-w-0">
                {#if formattedDate}
                    <span class="shrink-0">{formattedDate}</span>
                {/if}
                {#if trail.expand?.author?.preferred_username}
                    <img
                        class="rounded-full w-[18px] h-[18px] object-cover shrink-0"
                        src={trail.expand.author.icon ||
                            `https://api.dicebear.com/7.x/initials/svg?seed=${trail.expand.author.preferred_username}&backgroundType=gradientLinear`}
                        alt=""
                    />
                {/if}
                {#if authorLabel}
                    <span class="truncate">{authorLabel}</span>
                {/if}
            </div>
        {/if}

        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1.5 text-xs text-content/75">
            {#if trail.expand?.category?.name || trail.category}
                <span class="inline-flex items-center gap-1 font-medium text-content">
                    <span class="relative inline-block w-3.5 text-center">
                        <i class={`fa ${displayTrailCategoryIcon(trail)}`} aria-hidden="true"></i>
                        {#if displayTrailCategoryBadgeIcon(trail)}
                            <i
                                class={`fa ${displayTrailCategoryBadgeIcon(trail)} absolute -right-1 -top-1 text-[7px]`}
                                aria-hidden="true"
                            ></i>
                        {/if}
                    </span>
                    {displayCategoryName(
                        trail.expand?.category ?? { name: trail.category ?? "" },
                        $locale,
                    ) || $_("Hiking")}
                </span>
            {/if}
            {#if trail.difficulty}
                <span class="inline-flex items-center gap-1">
                    <i class="fa fa-gauge text-[11px]" aria-hidden="true"></i>
                    {$_(trail.difficulty)}
                </span>
            {/if}
            {#if trail.location}
                <span class="inline-flex items-center gap-1 min-w-0">
                    <i class="fa fa-location-dot text-[11px] shrink-0" aria-hidden="true"></i>
                    <span class="truncate max-w-[140px]">{trail.location}</span>
                </span>
            {/if}
        </div>

        <div class="flex flex-wrap gap-1.5 mt-2">
            <StatChip icon="fa-ruler" label={formatDistance(trail.distance)} />
            <StatChip icon="fa-clock" label={formatTimeHHMM(trailDisplayDuration(trail))} />
            <StatChip icon="fa-arrow-trend-up" label={formatElevation(trail.elevation_gain)} />
            {#if (trail.elevation_loss ?? 0) > 0}
                <StatChip icon="fa-arrow-trend-down" label={formatElevation(trail.elevation_loss)} />
            {/if}
        </div>

        <div class="mt-2.5 flex items-center justify-end gap-2">
            {#if ongroup}
                <button
                    type="button"
                    data-testid="mobile-card-group-btn"
                    onclick={() => ongroup(trail)}
                    class="inline-flex items-center gap-1.5 rounded-full border border-input-border/70 bg-content/[0.04] hover:bg-content/[0.09] text-content px-3.5 min-h-11 sm:min-h-9 text-xs font-semibold whitespace-nowrap cursor-pointer transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                >
                    <i class="fa-solid fa-user-group text-[11px]" aria-hidden="true"></i>
                    <span>{$_("group", { default: "Grup" })}</span>
                </button>
            {/if}
            <a
                href={navigateHref}
                class="inline-flex items-center gap-1.5 rounded-full bg-[#242734] hover:bg-[#242734]/90 text-white px-4 min-h-11 sm:min-h-9 text-xs font-semibold whitespace-nowrap shadow-sm transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
            >
                <i class="fa-solid fa-location-arrow text-[11px]" aria-hidden="true"></i>
                <span>{$_("start-trail", { default: "Navighează" })}</span>
            </a>
        </div>
    </div>
</article>
