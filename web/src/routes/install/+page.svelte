<script lang="ts">
    import MetaTags from "#lib/components/base/meta_tags.svelte";
    import { onMount } from "svelte";

    interface BeforeInstallPromptEvent extends Event {
        prompt: () => Promise<void>;
        userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
    }

    const IPA_URL =
        "https://github.com/Naffwoi/trasee-romania/releases/download/ios-latest/TraseeRomania-iOS-unsigned.ipa";
    const APK_URL =
        "https://github.com/Naffwoi/trasee-romania/releases/download/ios-latest/TraseeRomania-Android.apk";
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
            <i class="fa-brands fa-apple text-base" aria-hidden="true"></i>
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
            <i class="fa-brands fa-android text-base text-emerald-600" aria-hidden="true"></i>
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
                    BUILD NATIV FLUTTER (.IPA)
                </span>
                <h2 class="text-base font-bold">2. Fișierul nativ iOS (.ipa)</h2>
                <p class="text-xs text-content/65 mt-0.5">
                    Apple blochează instalarea directă din browser a fișierelor <code>.ipa</code> nesemnate cu certificat Apple. Pentru instalare nativă 100% wireless ai la dispoziție pachetul compilat automat pe GitHub (pentru TestFlight sau servicii de semnare OTA precum Signulous / Feather):
                </p>
            </div>

            <a
                href={IPA_URL}
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
                href={APK_URL}
                class="w-full py-3 px-4 rounded-2xl bg-emerald-700 hover:bg-emerald-800 text-white font-semibold text-sm flex items-center justify-center gap-2 transition-colors shadow-sm"
            >
                <i class="fa-brands fa-android text-base" aria-hidden="true"></i>
                <span>Descarcă TraseeRomania-Android.apk</span>
            </a>

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
