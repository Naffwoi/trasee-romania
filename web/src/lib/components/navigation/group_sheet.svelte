<script lang="ts">
    import {
        normalizeGroupCode,
        type GroupMemberDto,
        type GroupSessionDto,
    } from "#lib/live/live_client.ts";
    import { getGroupMemberInitials } from "#lib/live/report_markers.ts";
    import { haversineMeters } from "#lib/navigation/index.ts";
    import { formatDistance } from "#lib/util/format_util.ts";

    interface Props {
        open?: boolean;
        groupSession: GroupSessionDto | null;
        busy?: boolean;
        initialDisplayName?: string;
        selfLat?: number | null;
        selfLon?: number | null;
        selfAlongTrackM?: number | null;
        shareUrl?: string;
        onCreateGroup?: (displayName: string) => Promise<void> | void;
        onJoinGroup?: (code: string, displayName: string) => Promise<void> | void;
        onLeaveGroup?: () => Promise<void> | void;
        onFocusMember?: (member: GroupMemberDto) => void;
    }

    let {
        open = $bindable(false),
        groupSession,
        busy = false,
        initialDisplayName = "",
        selfLat = null,
        selfLon = null,
        selfAlongTrackM = null,
        shareUrl = "",
        onCreateGroup,
        onJoinGroup,
        onLeaveGroup,
        onFocusMember,
    }: Props = $props();

    let nameInput = $state("");
    let codeInput = $state("");
    let copied = $state(false);
    let copyResetTimer: ReturnType<typeof setTimeout> | null = null;

    $effect(() => {
        if (initialDisplayName && !nameInput) {
            nameInput = initialDisplayName.slice(0, 24);
        }
    });

    const normalizedJoinCode = $derived(normalizeGroupCode(codeInput));

    function resolveEffectiveName(): string {
        const trimmed = (nameInput || initialDisplayName || "Drumeț").trim().slice(0, 24);
        return trimmed || "Drumeț";
    }

    function safeAvatarBg(colorHex: string | undefined): string {
        const cleaned = (colorHex ?? "").trim();
        return /^#[0-9a-fA-F]{3,8}$/.test(cleaned) ? cleaned : "#242734";
    }

    function formatRelativeMemberDistance(m: GroupMemberDto): string {
        if (m.isSelf) return "Poziția ta";
        if (
            selfAlongTrackM !== null &&
            Number.isFinite(selfAlongTrackM) &&
            m.alongTrackM !== null &&
            m.alongTrackM !== undefined &&
            Number.isFinite(m.alongTrackM)
        ) {
            const deltaM = Math.round(m.alongTrackM - selfAlongTrackM);
            if (Math.abs(deltaM) < 10) {
                return "lângă tine";
            }
            const distLabel = formatDistance(Math.abs(deltaM), { compact: true });
            return deltaM > 0 ? `+${distLabel} în față` : `-${distLabel} în spate`;
        }
        if (
            selfLat !== null &&
            selfLon !== null &&
            Number.isFinite(selfLat) &&
            Number.isFinite(selfLon) &&
            Number.isFinite(m.lat) &&
            Number.isFinite(m.lon) &&
            (m.lat !== 0 || m.lon !== 0)
        ) {
            const distM = Math.round(haversineMeters(selfLat, selfLon, m.lat, m.lon));
            if (distM < 10) return "lângă tine";
            return `la ${formatDistance(distM, { compact: true })}`;
        }
        return "activ în grup";
    }

    function buildShareUrl(code: string): string {
        if (shareUrl.trim()) return shareUrl.trim();
        if (typeof window !== "undefined") {
            try {
                const u = new URL(window.location.href);
                u.searchParams.set("group", code);
                return u.toString();
            } catch {
                // Fall back to code
            }
        }
        return code;
    }

    async function handleCreate() {
        if (busy) return;
        await onCreateGroup?.(resolveEffectiveName());
    }

    async function handleJoin() {
        if (busy || !normalizedJoinCode) return;
        await onJoinGroup?.(normalizedJoinCode, resolveEffectiveName());
        codeInput = "";
    }

    async function handleShare() {
        if (!groupSession) return;
        const targetUrl = buildShareUrl(groupSession.code);
        try {
            if (typeof navigator !== "undefined" && typeof navigator.share === "function") {
                await navigator.share({
                    title: `Grup drumeție · ${groupSession.code}`,
                    text: `Intră în grupul live pe traseu (cod ${groupSession.code}):`,
                    url: targetUrl,
                });
                return;
            }
        } catch {
            // Fall through to clipboard copy if share sheet dismissed or unavailable
        }
        try {
            if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
                await navigator.clipboard.writeText(targetUrl);
                copied = true;
                if (copyResetTimer) clearTimeout(copyResetTimer);
                copyResetTimer = setTimeout(() => {
                    copied = false;
                }, 2000);
            }
        } catch {
            // Ignore clipboard permission errors
        }
    }

    async function handleLeave() {
        if (busy) return;
        await onLeaveGroup?.();
    }

    function handleMemberClick(m: GroupMemberDto) {
        if (m.isSelf) return;
        onFocusMember?.(m);
        open = false;
    }
</script>

{#if open}
    <div
        class="fixed inset-0 z-50 flex items-end justify-center bg-black/45 backdrop-blur-[2px] p-0 sm:p-4 pointer-events-auto"
        role="dialog"
        aria-modal="true"
        aria-label="Grup Live"
        data-testid="group-sheet"
    >
        <button
            type="button"
            aria-label="Închide"
            class="fixed inset-0 w-full h-full cursor-default"
            onclick={() => (open = false)}
        ></button>

        <div
            style="padding-bottom: calc(1rem + env(safe-area-inset-bottom, 0px));"
            class="relative z-10 w-full max-w-md bg-menu-background text-content rounded-t-3xl sm:rounded-3xl shadow-2xl border border-input-border/60 px-4 pt-3"
        >
            <div class="w-10 h-1 rounded-full bg-content/20 mx-auto mb-2.5"></div>

            <div class="flex items-center justify-between gap-2 mb-3">
                <div class="flex items-center gap-2">
                    <span
                        class="w-7 h-7 rounded-xl bg-[#242734] text-white flex items-center justify-center text-xs shrink-0"
                        aria-hidden="true"
                    >
                        <i class="fa-solid fa-user-group"></i>
                    </span>
                    <div>
                        <h2 class="text-sm font-extrabold tracking-tight leading-tight">
                            Grup Live
                        </h2>
                        <p class="text-[11px] text-content/60 leading-tight">
                            Poziții pe hartă &amp; stabilizare GPS în pădure
                        </p>
                    </div>
                </div>
                <button
                    type="button"
                    aria-label="Închide"
                    onclick={() => (open = false)}
                    class="w-7 h-7 rounded-full bg-content/[0.08] hover:bg-content/15 text-content/75 flex items-center justify-center text-xs cursor-pointer shrink-0"
                >
                    <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                </button>
            </div>

            {#if groupSession === null}
                <div class="space-y-3">
                    <div>
                        <label
                            for="group-name-input"
                            class="block text-[11px] font-semibold text-content/70 mb-1"
                        >
                            Numele tău pe hartă
                        </label>
                        <input
                            id="group-name-input"
                            data-testid="group-name-input"
                            type="text"
                            maxlength="24"
                            bind:value={nameInput}
                            placeholder="ex. Diana, Andrei..."
                            class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2 text-xs font-medium text-content placeholder:text-content/45 focus:outline-none focus:ring-2 focus:ring-[#242734]/30"
                        />
                    </div>

                    <button
                        type="button"
                        data-testid="group-create-btn"
                        disabled={busy}
                        onclick={handleCreate}
                        class="w-full rounded-2xl bg-[#242734] text-white hover:bg-[#242734]/90 active:scale-[0.99] transition-all py-2.5 px-4 text-xs font-bold flex items-center justify-center gap-2 cursor-pointer disabled:opacity-50 shadow-sm"
                    >
                        <i class="fa-solid fa-plus text-[11px]" aria-hidden="true"></i>
                        <span>Creează grup</span>
                    </button>

                    <div class="flex items-center gap-2 py-0.5">
                        <div class="h-px flex-1 bg-input-border/50"></div>
                        <span class="text-[10.5px] font-semibold uppercase tracking-wider text-content/45">
                            sau intră cu cod
                        </span>
                        <div class="h-px flex-1 bg-input-border/50"></div>
                    </div>

                    <div class="flex items-center gap-2">
                        <input
                            id="group-code-input"
                            data-testid="group-code-input"
                            type="text"
                            maxlength="6"
                            autocapitalize="characters"
                            autocomplete="off"
                            spellcheck="false"
                            value={codeInput}
                            oninput={(e) => {
                                codeInput = (e.currentTarget as HTMLInputElement).value
                                    .toUpperCase()
                                    .replace(/[^A-Z0-9]/g, "")
                                    .slice(0, 6);
                            }}
                            onkeydown={(e) => {
                                if (e.key === "Enter" && normalizedJoinCode && !busy) {
                                    e.preventDefault();
                                    void handleJoin();
                                }
                            }}
                            placeholder="K7M9P2"
                            aria-label="Cod grup (6 caractere)"
                            class="flex-1 rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2 text-sm font-mono font-extrabold tracking-[0.22em] uppercase text-center text-content placeholder:text-content/35 placeholder:tracking-[0.18em] focus:outline-none focus:ring-2 focus:ring-[#242734]/30"
                        />
                        <button
                            type="button"
                            data-testid="group-join-btn"
                            disabled={busy || normalizedJoinCode === null}
                            onclick={handleJoin}
                            class="rounded-xl bg-[#242734] text-white hover:bg-[#242734]/90 px-4 py-2 text-xs font-bold cursor-pointer disabled:opacity-40 shrink-0"
                        >
                            Intră
                        </button>
                    </div>
                </div>
            {:else}
                <div class="space-y-3">
                    <div
                        class="rounded-2xl bg-content/[0.04] border border-input-border/60 px-3.5 py-2.5 flex items-center justify-between gap-2"
                    >
                        <div>
                            <div class="text-[10.5px] font-semibold uppercase tracking-wider text-content/55">
                                Cod grup activ
                            </div>
                            <div
                                data-testid="group-active-code"
                                class="font-mono text-lg font-extrabold tracking-[0.22em] text-content leading-tight mt-0.5"
                            >
                                {groupSession.code}
                            </div>
                        </div>

                        <button
                            type="button"
                            data-testid="group-share-btn"
                            onclick={handleShare}
                            class="rounded-xl bg-[#242734] text-white hover:bg-[#242734]/90 px-3 py-2 text-xs font-bold inline-flex items-center gap-1.5 cursor-pointer shrink-0"
                        >
                            <i
                                class={`fa-solid ${copied ? "fa-check" : "fa-share-nodes"} text-[11px]`}
                                aria-hidden="true"
                            ></i>
                            <span>{copied ? "Link copiat" : "Distribuie link"}</span>
                        </button>
                    </div>

                    <div class="max-h-56 overflow-y-auto space-y-1.5 pr-0.5">
                        {#each groupSession.members as member (member.memberId)}
                            <button
                                type="button"
                                data-testid="group-member-row"
                                disabled={member.isSelf}
                                onclick={() => handleMemberClick(member)}
                                class={`w-full rounded-2xl border border-input-border/50 px-3 py-2 flex items-center gap-2.5 text-left transition-colors ${
                                    member.isSelf
                                        ? "bg-content/[0.03] cursor-default"
                                        : "bg-content/[0.04] hover:bg-content/[0.09] cursor-pointer"
                                }`}
                            >
                                <span
                                    class="w-8 h-8 rounded-full text-white text-[11px] font-extrabold flex items-center justify-center shrink-0 border-2 border-white shadow-sm"
                                    style={`background:${safeAvatarBg(member.colorHex)};`}
                                    aria-hidden="true"
                                >
                                    {getGroupMemberInitials(member.displayName)}
                                </span>

                                <div class="flex-1 min-w-0">
                                    <div class="flex items-center gap-1.5">
                                        <span class="text-xs font-bold text-content truncate">
                                            {member.displayName}
                                        </span>
                                        {#if member.isSelf}
                                            <span
                                                class="text-[10px] font-bold px-1.5 py-0.2 rounded-full bg-content/[0.08] text-content/70"
                                            >
                                                Tu
                                            </span>
                                        {/if}
                                    </div>
                                    <div class="text-[11px] text-content/65 truncate">
                                        {formatRelativeMemberDistance(member)}
                                        {#if member.accuracy > 0}
                                            <span> · ±{Math.max(1, Math.round(member.accuracy))} m</span>
                                        {/if}
                                    </div>
                                </div>

                                {#if !member.isSelf}
                                    <i
                                        class="fa-solid fa-location-crosshairs text-xs text-content/45 shrink-0"
                                        aria-hidden="true"
                                    ></i>
                                {/if}
                            </button>
                        {/each}
                    </div>

                    <button
                        type="button"
                        data-testid="group-leave-btn"
                        disabled={busy}
                        onclick={handleLeave}
                        class="w-full rounded-xl bg-content/[0.06] hover:bg-content/[0.12] text-content/80 border border-input-border/60 py-2 px-3 text-xs font-semibold cursor-pointer disabled:opacity-50"
                    >
                        Ieși din grup
                    </button>
                </div>
            {/if}
        </div>
    </div>
{/if}
