<script lang="ts">
    import MetaTags from "#lib/components/base/meta_tags.svelte";
    import { onMount } from "svelte";

    interface BeforeInstallPromptEvent extends Event {
        prompt: () => Promise<void>;
        userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
    }

    const IPA_URL =
        "https://trasee.skillfy.ro/downloads/TraseeRomania-iOS-unsigned.ipa";
    const APK_ARM64_URL =
        "https://trasee.skillfy.ro/downloads/TraseeRomania-Android-arm64.apk";
    const APK_URL =
        "https://trasee.skillfy.ro/downloads/TraseeRomania-Android.apk";
    const RELEASE_PAGE_URL =
        "https://github.com/Naffwoi/trasee-romania/releases/tag/ios-latest";
    const TEST_TRAIL_URL = "/map/trail/@romania/ayl2z0tf824rp3n";

    let selectedPlatform = $state<"ios" | "android">("ios");
    let isStandalone = $state(false);
    let deferredPrompt = $state<BeforeInstallPromptEvent | null>(null);
    let installedViaPrompt = $state(false);

    onMount(() => {
        const ua = navigator.userAgent || "";
        if (/android/i.test(ua)) {
            selectedPlatform = "android";
        } else {
            selectedPlatform = "ios";
        }

        isStandalone =
            window.matchMedia?.("(display-mode: standalone)")?.matches === true ||
            (navigator as unknown as { standalone?: boolean }).standalone === true;

        const handleBeforeInstall = (e: Event) => {
            e.preventDefault();
            deferredPrompt = e as BeforeInstallPromptEvent;
        };
        window.addEventListener("beforeinstallprompt", handleBeforeInstall);
        return () => {
            window.removeEventListener("beforeinstallprompt", handleBeforeInstall);
        };
    });

    async function triggerAndroidPwaInstall() {
        if (!deferredPrompt) return;
        await deferredPrompt.prompt();
        const choice = await deferredPrompt.userChoice;
        if (choice.outcome === "accepted") {
            installedViaPrompt = true;
            deferredPrompt = null;
        }
    }
</script>

<MetaTags title="Instalează Trasee România pe iPhone & Android" />

<main class="max-w-xl mx-auto px-4 pt-6 pb-28 text-content space-y-5">
    <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-3">
            <img
                src="/apple-touch-icon.png"
                alt="Trasee România"
                class="w-12 h-12 rounded-2xl shadow-md border border-input-border/50"
            />
            <div>
                <h1 class="text-xl font-extrabold tracking-tight leading-tight">
                    Trasee România
                </h1>
                <p class="text-xs text-content/65">
                    Instalare wireless pe iPhone și Android · fără cablu
                </p>
            </div>
        </div>
        <a
            href="/map"
            class="px-3.5 py-2 rounded-full bg-content/[0.07] hover:bg-secondary-hover text-xs font-semibold transition-colors"
        >
            Deschide harta
        </a>
    </div>

    {#if isStandalone || installedViaPrompt}
        <div
            class="rounded-2xl bg-emerald-600/12 border border-emerald-500/35 p-4 text-sm font-semibold text-emerald-700 dark:text-emerald-300 flex items-center gap-3"
        >
            <i class="fa-solid fa-circle-check text-lg" aria-hidden="true"></i>
            <span>Aplicația este deja instalată pe telefonul tău!</span>
        </div>
    {/if}

    <!-- Platform Switcher -->
    <div class="grid grid-cols-2 gap-1.5 p-1 rounded-2xl bg-content/[0.06] border border-input-border/40">
        <button
            type="button"
            onclick={() => (selectedPlatform = "ios")}
            class={`py-2.5 px-3 rounded-xl text-sm font-bold flex items-center justify-center gap-2 cursor-pointer transition-colors ${
                selectedPlatform === "ios"
                    ? "bg-menu-background text-content shadow-sm"
                    : "text-content/65 hover:text-content"
            }`}
        >
            <svg class="w-4 h-4 fill-current shrink-0" viewBox="0 0 384 512" aria-hidden="true">
                <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"/>
            </svg>
            <span>iPhone (iOS)</span>
        </button>
        <button
            type="button"
            onclick={() => (selectedPlatform = "android")}
            class={`py-2.5 px-3 rounded-xl text-sm font-bold flex items-center justify-center gap-2 cursor-pointer transition-colors ${
                selectedPlatform === "android"
                    ? "bg-menu-background text-content shadow-sm"
                    : "text-content/65 hover:text-content"
            }`}
        >
            <svg class="w-4 h-4 fill-current text-emerald-600 shrink-0" viewBox="0 0 576 512" aria-hidden="true">
                <path d="M420.55,301.93a24,24,0,1,1,24-24,24,24,0,0,1-24,24m-265.1,0a24,24,0,1,1,24-24,24,24,0,0,1-24,24m273.7-144.48,47.94-83a10,10,0,1,0-17.27-10h0l-48.54,84.07a301.25,301.25,0,0,0-246.56,0L116.18,64.45a10,10,0,1,0-17.27,10h0l47.94,83C64.53,202.22,8.24,285.55,0,384H576c-8.24-98.45-64.54-181.78-146.85-226.55"/>
            </svg>
            <span>Android</span>
        </button>
    </div>

    {#if selectedPlatform === "ios"}
        <!-- Option 1: Instant Safari Standalone Web App (Zero Cable, Never Expires) -->
        <section
            class="rounded-3xl bg-menu-background border border-emerald-500/40 shadow-md p-5 space-y-4"
        >
            <div class="flex items-start justify-between gap-2">
                <div>
                    <span
                        class="inline-block px-2.5 py-0.5 rounded-full bg-emerald-600/15 text-emerald-700 dark:text-emerald-300 text-[11px] font-bold mb-1.5"
                    >
                        RECOMANDAT · 100% FĂRĂ CABLU · NU EXPIRĂ
                    </span>
                    <h2 class="text-base font-bold">
                        1. Instalare direct din Safari pe iPhone (15 secunde)
                    </h2>
                    <p class="text-xs text-content/65 mt-0.5">
                        Rulează full-screen ca aplicație nativă, cu GPS live, busolă și redresare off-trail.
                    </p>
                </div>
            </div>

            <ol class="space-y-3 text-sm">
                <li class="flex items-start gap-3">
                    <span
                        class="w-6 h-6 rounded-full bg-emerald-600 text-white text-xs font-bold flex items-center justify-center shrink-0 mt-0.5"
                        >1</span
                    >
                    <span>
                        Deschide această pagină (<strong>trasee.skillfy.ro/install</strong>) în
                        <strong>Safari</strong> pe iPhone.
                    </span>
                </li>
                <li class="flex items-start gap-3">
                    <span
                        class="w-6 h-6 rounded-full bg-emerald-600 text-white text-xs font-bold flex items-center justify-center shrink-0 mt-0.5"
                        >2</span
                    >
                    <span>
                        Apasă iconița <strong>Share (Partajează)</strong>
                        <i
                            class="fa-solid fa-arrow-up-from-bracket mx-1 text-blue-500"
                            aria-hidden="true"
                        ></i> din bara de jos a Safari.
                    </span>
                </li>
                <li class="flex items-start gap-3">
                    <span
                        class="w-6 h-6 rounded-full bg-emerald-600 text-white text-xs font-bold flex items-center justify-center shrink-0 mt-0.5"
                        >3</span
                    >
                    <span>
                        Alege <strong>„Adaugă la ecranul principal”</strong>
                        (<em>Add to Home Screen</em>) → <strong>Adaugă</strong>.
                    </span>
                </li>
            </ol>
        </section>

        <!-- Option 2: Native Flutter iOS .IPA -->
        <section
            class="rounded-3xl bg-menu-background border border-input-border/60 shadow-sm p-5 space-y-3.5"
        >
            <div>
                <span
                    class="inline-block px-2.5 py-0.5 rounded-full bg-content/[0.08] text-content/75 text-[11px] font-bold mb-1.5"
                >
                    SIDE-LOAD NATIV (.IPA / REPO JSON)
                </span>
                <h2 class="text-base font-bold">2. SideStore / AltStore Classic / Feather</h2>
                <p class="text-xs text-content/65 mt-0.5">
                    Dacă adaugi sursa în <strong>Sources (+)</strong>, folosește URL-ul JSON de mai jos (nu linkul <code>.ipa</code> direct). Sau descarcă fișierul <code>.ipa</code> în <strong>Files</strong> și încarcă-l din <strong>My Apps → +</strong>.
                </p>
            </div>

            <div class="rounded-2xl bg-content/[0.05] border border-input-border/50 px-3.5 py-2.5 text-xs font-mono break-all select-all">
                https://trasee.skillfy.ro/altstore.json
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <a
                    href="sidestore://source?url=https://trasee.skillfy.ro/altstore.json"
                    class="py-2.5 px-3 rounded-2xl bg-indigo-600 hover:bg-indigo-700 text-white font-semibold text-xs flex items-center justify-center gap-2 transition-colors"
                >
                    <i class="fa-solid fa-plus" aria-hidden="true"></i>
                    <span>Adaugă în SideStore</span>
                </a>
                <a
                    href="altstore://source?url=https://trasee.skillfy.ro/altstore.json"
                    class="py-2.5 px-3 rounded-2xl bg-teal-600 hover:bg-teal-700 text-white font-semibold text-xs flex items-center justify-center gap-2 transition-colors"
                >
                    <i class="fa-solid fa-plus" aria-hidden="true"></i>
                    <span>Adaugă în AltStore</span>
                </a>
            </div>

            <a
                href={IPA_URL}
                rel="external"
                download="TraseeRomania-iOS-unsigned.ipa"
                class="w-full py-3 px-4 rounded-2xl bg-content text-background font-semibold text-sm flex items-center justify-center gap-2 hover:opacity-90 transition-opacity"
            >
                <i class="fa-solid fa-download" aria-hidden="true"></i>
                <span>Descarcă TraseeRomania-iOS-unsigned.ipa</span>
            </a>
        </section>
    {:else}
        <!-- Android Option 1: Direct APK Download (100% Cable-Free) -->
        <section
            class="rounded-3xl bg-menu-background border border-emerald-500/40 shadow-md p-5 space-y-4"
        >
            <div>
                <span
                    class="inline-block px-2.5 py-0.5 rounded-full bg-emerald-600/15 text-emerald-700 dark:text-emerald-300 text-[11px] font-bold mb-1.5"
                >
                    APLICAȚIE NATIVĂ ANDROID · FĂRĂ CABLU
                </span>
                <h2 class="text-base font-bold">
                    1. Descarcă și instalează direct fișierul .APK
                </h2>
                <p class="text-xs text-content/65 mt-0.5">
                    Aplicația nativă Flutter preconfigurată cu serverul <strong>trasee.skillfy.ro</strong>. Descarc-o direct pe telefon și deschide fișierul pentru instalare.
                </p>
            </div>

            <a
                href={APK_ARM64_URL}
                rel="external"
                download="TraseeRomania-Android-arm64.apk"
                class="w-full py-3 px-4 rounded-2xl bg-emerald-700 hover:bg-emerald-800 text-white font-semibold text-sm flex items-center justify-center gap-2 transition-colors shadow-sm"
            >
                <svg class="w-4 h-4 fill-current shrink-0" viewBox="0 0 576 512" aria-hidden="true">
                    <path d="M420.55,301.93a24,24,0,1,1,24-24,24,24,0,0,1-24,24m-265.1,0a24,24,0,1,1,24-24,24,24,0,0,1-24,24m273.7-144.48,47.94-83a10,10,0,1,0-17.27-10h0l-48.54,84.07a301.25,301.25,0,0,0-246.56,0L116.18,64.45a10,10,0,1,0-17.27,10h0l47.94,83C64.53,202.22,8.24,285.55,0,384H576c-8.24-98.45-64.54-181.78-146.85-226.55"/>
                </svg>
                <span>Descarcă APK Rapid (Android arm64 · ~20 MB)</span>
            </a>

            <div class="text-center">
                <a
                    href={APK_URL}
                    rel="external"
                    download="TraseeRomania-Android.apk"
                    class="text-[11px] text-content/65 underline hover:text-content"
                >
                    Telefon mai vechi (32-bit)? Descarcă pachetul universal TraseeRomania-Android.apk
                </a>
            </div>

            <p class="text-[11px] text-content/60">
                Dacă Android afișează <em>„Instalați aplicații necunoscute”</em> sau Play Protect, apasă <strong>Permite / Instalează oricum</strong>.
            </p>
        </section>

        <!-- Android Option 2: Instant Chrome Web App -->
        <section
            class="rounded-3xl bg-menu-background border border-input-border/60 shadow-sm p-5 space-y-3.5"
        >
            <div>
                <span
                    class="inline-block px-2.5 py-0.5 rounded-full bg-content/[0.08] text-content/75 text-[11px] font-bold mb-1.5"
                >
                    ALTERNATIVĂ INSTANTĂ (PWA)
                </span>
                <h2 class="text-base font-bold">2. Instalează instant din Chrome</h2>
                <p class="text-xs text-content/65 mt-0.5">
                    Fără descărcare de APK: în Chrome pe Android apasă meniul <strong>⋮</strong> (dreapta sus) → <strong>„Instalează aplicația” (Install app)</strong>.
                </p>
            </div>

            {#if deferredPrompt}
                <button
                    type="button"
                    onclick={triggerAndroidPwaInstall}
                    class="w-full py-3 px-4 rounded-2xl bg-blue-600 hover:bg-blue-700 text-white font-semibold text-sm flex items-center justify-center gap-2 cursor-pointer transition-colors"
                >
                    <i class="fa-solid fa-mobile-screen-button" aria-hidden="true"></i>
                    <span>Instalează acum cu un tap</span>
                </button>
            {/if}
        </section>
    {/if}

    <!-- Quick Link to GBC -> Piata Domenii Test Trail -->
    <div
        class="rounded-3xl bg-content/[0.04] border border-input-border/50 p-4 flex items-center justify-between gap-3"
    >
        <div class="min-w-0">
            <div class="text-xs font-bold text-emerald-600 dark:text-emerald-400">
                TRASEU DE TEST PREGĂTIT
            </div>
            <div class="text-sm font-semibold truncate">GBC – Piața Domenii (2.11 km)</div>
        </div>
        <a
            href={TEST_TRAIL_URL}
            class="px-4 py-2 rounded-full bg-emerald-700 hover:bg-emerald-800 text-white text-xs font-bold shrink-0 transition-colors"
        >
            Deschide traseul
        </a>
    </div>

    <div class="text-center text-xs text-content/50">
        <a href={RELEASE_PAGE_URL} target="_blank" rel="noreferrer" class="underline hover:text-content">
            Vezi toate pachetele (.ipa & .apk) pe GitHub Releases
        </a>
    </div>
</main>
