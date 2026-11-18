<script lang="ts">
    import { browser } from "$app/env";
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
        initialTrailName?: string;
        initialJoinCode?: string;
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
        initialTrailName = "",
        initialJoinCode = "",
        selfLat = null,
        selfLon = null,
        selfAlongTrackM = null,
        shareUrl = "",
        onCreateGroup,
        onJoinGroup,
        onLeaveGroup,
        onFocusMember,
    }: Props = $props();

    let dialogEl = $state<HTMLDialogElement | undefined>();
    let activeTab = $state<"live" | "plan">("live");
    let nameInput = $state("");
    let codeInput = $state("");
    let planTrailInput = $state("");
    let planDateInput = $state("");
    let planTimeInput = $state("08:30");
    let planMeetingInput = $state("");
    let copied = $state(false);
    let planCopied = $state(false);
    let copyResetTimer: ReturnType<typeof setTimeout> | null = null;

    function generatePlanCode(): string {
        const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        let out = "";
        for (let i = 0; i < 6; i++) {
            out += alphabet[Math.floor(Math.random() * alphabet.length)];
        }
        return out;
    }
    const planFallbackCode = generatePlanCode();

    $effect(() => {
        if (!browser) return;
        if (open && dialogEl && !dialogEl.open) {
            try {
                dialogEl.showModal?.();
            } catch {
                // Non-fatal in DOM test shims without full showModal support
            }
        }
    });

    $effect(() => {
        if (initialDisplayName && !nameInput) {
            nameInput = initialDisplayName.slice(0, 24);
        }
    });

    $effect(() => {
        if (initialTrailName && !planTrailInput) {
            planTrailInput = initialTrailName;
        }
    });

    $effect(() => {
        const seedCode = normalizeGroupCode(initialJoinCode);
        if (open && seedCode && !codeInput) {
            codeInput = seedCode;
        }
    });

    $effect(() => {
        if (!planDateInput) {
            const tomorrow = new Date(Date.now() + 86_400_000);
            planDateInput = tomorrow.toISOString().slice(0, 10);
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

    async function handlePlanShare() {
        const code = groupSession?.code ?? planFallbackCode;
        const link = buildShareUrl(code);
        const lines = [
            `Invitație drumeție${planTrailInput.trim() ? `: ${planTrailInput.trim()}` : ""}`,
            `Când: ${planDateInput} la ${planTimeInput}`,
            planMeetingInput.trim() ? `Întâlnire: ${planMeetingInput.trim()}` : "",
            `Cod grup live: ${code}`,
            link.startsWith("http") ? `Link: ${link}` : "",
        ].filter(Boolean);
        const payload = lines.join("\n");
        try {
            if (typeof navigator !== "undefined" && typeof navigator.share === "function") {
                await navigator.share({
                    title: `Invitație tură${planTrailInput.trim() ? ` · ${planTrailInput.trim()}` : ""}`,
                    text: payload,
                });
                return;
            }
        } catch {
            // Fall through to clipboard copy
        }
        try {
            if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
                await navigator.clipboard.writeText(payload);
                planCopied = true;
                setTimeout(() => {
                    planCopied = false;
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
    <dialog
        bind:this={dialogEl}
        data-testid="group-sheet"
        aria-label="Grup Live"
        onclose={() => (open = false)}
        onclick={(e) => {
            if (e.target === dialogEl) open = false;
        }}
        class="group-sheet-dialog fixed inset-0 z-50 m-0 w-full max-w-none h-dvh max-h-none bg-transparent p-0 sm:p-4 flex items-end justify-center border-0 overscroll-contain pointer-events-auto"
    >
        <div
            style="padding-bottom: calc(1rem + env(safe-area-inset-bottom, 0px));"
            class="relative z-10 w-full max-w-md bg-menu-background text-content rounded-t-3xl sm:rounded-3xl shadow-2xl border border-input-border/60 px-4 pt-3 max-h-[92dvh] overflow-y-auto overscroll-contain"
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
                            Poziții pe hartă &amp; planificare tură
                        </p>
                    </div>
                </div>
                <button
                    type="button"
                    aria-label="Închide"
                    onclick={() => (open = false)}
                    class="w-11 h-11 -mr-1.5 rounded-full hover:bg-content/10 text-content/75 flex items-center justify-center text-sm cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                >
                    <span class="w-7 h-7 rounded-full bg-content/[0.08] flex items-center justify-center">
                        <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                    </span>
                </button>
            </div>

            <div
                class="grid grid-cols-2 gap-1 p-1 rounded-xl bg-content/[0.06] mb-3"
                role="tablist"
                aria-label="Mod grup"
            >
                <button
                    type="button"
                    role="tab"
                    aria-selected={activeTab === "live"}
                    onclick={() => (activeTab = "live")}
                    class={`min-h-11 sm:min-h-9 rounded-lg text-xs font-bold cursor-pointer transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734] ${
                        activeTab === "live"
                            ? "bg-menu-background text-content shadow-xs"
                            : "text-content/65 hover:text-content"
                    }`}
                >
                    Grup Live Acum
                </button>
                <button
                    type="button"
                    role="tab"
                    aria-selected={activeTab === "plan"}
                    onclick={() => (activeTab = "plan")}
                    class={`min-h-11 sm:min-h-9 rounded-lg text-xs font-bold cursor-pointer transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734] ${
                        activeTab === "plan"
                            ? "bg-menu-background text-content shadow-xs"
                            : "text-content/65 hover:text-content"
                    }`}
                >
                    Planifică Tură
                </button>
            </div>

            {#if activeTab === "plan"}
                <div class="space-y-3">
                    <div>
                        <label
                            for="group-plan-trail"
                            class="block text-[11px] font-semibold text-content/70 mb-1"
                        >
                            Traseu / destinație
                        </label>
                        <input
                            id="group-plan-trail"
                            type="text"
                            bind:value={planTrailInput}
                            placeholder="ex. Masivul Piatra Mare"
                            class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-xs font-medium text-content placeholder:text-content/45 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                        />
                    </div>
                    <div class="grid grid-cols-2 gap-2">
                        <div>
                            <label
                                for="group-plan-date"
                                class="block text-[11px] font-semibold text-content/70 mb-1"
                            >
                                Data
                            </label>
                            <input
                                id="group-plan-date"
                                type="date"
                                bind:value={planDateInput}
                                class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-xs font-medium text-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                            />
                        </div>
                        <div>
                            <label
                                for="group-plan-time"
                                class="block text-[11px] font-semibold text-content/70 mb-1"
                            >
                                Ora plecării
                            </label>
                            <input
                                id="group-plan-time"
                                type="time"
                                bind:value={planTimeInput}
                                class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-xs font-medium text-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                            />
                        </div>
                    </div>
                    <div>
                        <label
                            for="group-plan-meeting"
                            class="block text-[11px] font-semibold text-content/70 mb-1"
                        >
                            Loc de întâlnire
                        </label>
                        <input
                            id="group-plan-meeting"
                            type="text"
                            bind:value={planMeetingInput}
                            placeholder="ex. Gara Predeal · intrare traseu"
                            class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-xs font-medium text-content placeholder:text-content/45 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                        />
                    </div>
                    <div
                        class="rounded-xl bg-content/[0.04] border border-input-border/50 px-3 py-2 flex items-center justify-between text-xs"
                    >
                        <span class="text-content/65 font-medium">Cod grup atașat</span>
                        <span class="font-mono font-extrabold tracking-[0.2em]">
                            {groupSession?.code ?? planFallbackCode}
                        </span>
                    </div>
                    <button
                        type="button"
                        onclick={handlePlanShare}
                        class="w-full rounded-2xl bg-[#242734] text-white hover:bg-[#242734]/90 min-h-11 px-4 text-xs font-bold flex items-center justify-center gap-2 cursor-pointer shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                    >
                        <i
                            class={`fa-solid ${planCopied ? "fa-check" : "fa-share-nodes"} text-[11px]`}
                            aria-hidden="true"
                        ></i>
                        <span>{planCopied ? "Invitație copiată" : "Trimite invitația de tură"}</span>
                    </button>
                </div>
            {:else if groupSession === null}
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
                            class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-xs font-medium text-content placeholder:text-content/45 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                        />
                    </div>

                    <button
                        type="button"
                        data-testid="group-create-btn"
                        disabled={busy}
                        onclick={handleCreate}
                        class="w-full rounded-2xl bg-[#242734] text-white hover:bg-[#242734]/90 active:scale-[0.99] transition-all min-h-11 px-4 text-xs font-bold flex items-center justify-center gap-2 cursor-pointer disabled:opacity-50 shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
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
                            class="flex-1 rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2.5 text-sm font-mono font-extrabold tracking-[0.22em] uppercase text-center text-content placeholder:text-content/35 placeholder:tracking-[0.18em] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                        />
                        <button
                            type="button"
                            data-testid="group-join-btn"
                            disabled={busy || normalizedJoinCode === null}
                            onclick={handleJoin}
                            class="rounded-xl bg-[#242734] text-white hover:bg-[#242734]/90 px-4 min-h-11 text-xs font-bold cursor-pointer disabled:opacity-40 shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
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
                            class="rounded-xl bg-[#242734] text-white hover:bg-[#242734]/90 px-3 min-h-11 sm:min-h-9 text-xs font-bold inline-flex items-center gap-1.5 cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
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
                                class={`w-full rounded-2xl border border-input-border/50 px-3 py-2 flex items-center gap-2.5 text-left transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734] ${
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
                        class="w-full rounded-xl bg-content/[0.06] hover:bg-content/[0.12] text-content/80 border border-input-border/60 min-h-11 px-3 text-xs font-semibold cursor-pointer disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
                    >
                        Ieși din grup
                    </button>
                </div>
            {/if}
        </div>
    </dialog>
{/if}

<style>
    .group-sheet-dialog::backdrop {
        background: rgba(0, 0, 0, 0.45);
        backdrop-filter: blur(2px);
    }
</style>
