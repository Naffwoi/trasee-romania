<script lang="ts">
    import { goto } from "$app/navigation";
    import { page } from "$app/state";
    import { theme, toggleTheme } from "#lib/stores/theme_store.ts";
    import { currentUser, logout } from "#lib/stores/user_store.ts";
    import { getFileURL } from "#lib/util/file_util.ts";
    import type { AuthRecord } from "pocketbase";
    import { _ } from "svelte-i18n";
    import UrlImportModal from "./settings/url_import_modal.svelte";

    interface Props {
        user: AuthRecord;
    }

    let { user }: Props = $props();
    // `currentUser` is undefined until the client auth store has been initialised.
    const navUser = $derived($currentUser === undefined ? user : $currentUser);

    let createMenuOpen = $state(false);
    let profileMenuOpen = $state(false);
    let navElement = $state<HTMLElement>();
    let urlImportModal: UrlImportModal;

    const pathname = $derived(page.url.pathname);
    const activeTab = $derived.by(() => {
        if (pathname === "/map" || pathname.startsWith("/map/trail")) return "trails";
        if (pathname.startsWith("/lists")) return "lists";
        if (pathname.startsWith("/trails")) return "library";
        if (
            pathname.startsWith("/profile") ||
            pathname.startsWith("/settings") ||
            pathname.startsWith("/login") ||
            pathname.startsWith("/register")
        ) {
            return "profile";
        }
        return "";
    });

    function closeMenus() {
        createMenuOpen = false;
        profileMenuOpen = false;
    }

    function handleOutsidePointer(event: PointerEvent) {
        if (!createMenuOpen && !profileMenuOpen) return;
        if (event.target instanceof Node && !navElement?.contains(event.target)) {
            closeMenus();
        }
    }

    function handleKeydown(event: KeyboardEvent) {
        if (event.key === "Escape" && (createMenuOpen || profileMenuOpen)) {
            event.preventDefault();
            closeMenus();
        }
    }

    function handleLogout() {
        closeMenus();
        void logout();
        window.location.assign("/map");
    }
</script>

<svelte:window onpointerdown={handleOutsidePointer} onkeydown={handleKeydown} />

<nav
    bind:this={navElement}
    aria-label="Primary navigation"
    class="app-navbar fixed bottom-0 inset-x-0 z-45 h-16 bg-menu-background/98 backdrop-blur-md border-t border-input-border/50 shadow-[0_-2px_16px_rgba(0,0,0,0.08)] select-none"
>
    <div class="max-w-3xl mx-auto h-full flex items-center justify-around px-2 relative">
        <!-- 1. Trails (/map) -->
        <a
            href="/map"
            onclick={closeMenus}
            aria-current={activeTab === "trails" ? "page" : undefined}
            class="flex flex-col items-center justify-center gap-0.5 px-3 py-1 rounded-2xl transition-colors {activeTab === 'trails'
                ? 'text-primary'
                : 'text-content/55 hover:text-content/85'}"
        >
            <i class="fa-solid fa-map-location-dot text-[20px] leading-none" aria-hidden="true"></i>
            <span class="text-[11px] font-medium leading-tight">
                {$_("trail", { values: { n: 2 } })}
            </span>
        </a>

        <!-- 2. Lists (/lists) -->
        <a
            href="/lists"
            onclick={closeMenus}
            aria-current={activeTab === "lists" ? "page" : undefined}
            class="flex flex-col items-center justify-center gap-0.5 px-3 py-1 rounded-2xl transition-colors {activeTab === 'lists'
                ? 'text-primary'
                : 'text-content/55 hover:text-content/85'}"
        >
            <i class="fa-solid fa-list text-[20px] leading-none" aria-hidden="true"></i>
            <span class="text-[11px] font-medium leading-tight">
                {$_("list", { values: { n: 2 } })}
            </span>
        </a>

        <!-- 3. Center Docked '+' FAB -->
        <div class="relative flex items-center justify-center w-14">
            <button
                type="button"
                aria-label={$_("create")}
                aria-expanded={createMenuOpen}
                onclick={() => {
                    profileMenuOpen = false;
                    createMenuOpen = !createMenuOpen;
                }}
                class="-mt-7 w-14 h-14 rounded-full bg-menu-background text-content border border-input-border/60 shadow-[0_4px_14px_rgba(0,0,0,0.20)] flex items-center justify-center cursor-pointer hover:scale-105 active:scale-95 transition-transform"
            >
                <i class="fa-solid fa-plus text-lg" aria-hidden="true"></i>
            </button>

            {#if createMenuOpen}
                <div
                    role="menu"
                    class="absolute bottom-14 left-1/2 -translate-x-1/2 w-52 rounded-2xl bg-menu-background text-content border border-input-border/70 shadow-[0_10px_30px_rgba(0,0,0,0.18)] p-1.5 z-60"
                >
                    <a
                        href="/trail/edit/new"
                        data-sveltekit-reload
                        onclick={closeMenus}
                        class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                    >
                        <i class="fa-solid fa-route w-4 text-center text-content/70" aria-hidden="true"></i>
                        <span>{$_("new-trail")}</span>
                    </a>
                    <a
                        href="/lists/edit/new"
                        onclick={closeMenus}
                        class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                    >
                        <i class="fa-solid fa-list-ul w-4 text-center text-content/70" aria-hidden="true"></i>
                        <span>{$_("new-list")}</span>
                    </a>
                    {#if navUser}
                        <div class="border-t border-input-border/50 my-1"></div>
                        <a
                            href="/settings/export"
                            onclick={closeMenus}
                            class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                        >
                            <i class="fa-solid fa-file-import w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("from-file")}</span>
                        </a>
                        <button
                            type="button"
                            onclick={() => {
                                closeMenus();
                                urlImportModal.openModal();
                            }}
                            class="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium text-left hover:bg-secondary-hover cursor-pointer"
                        >
                            <i class="fa-solid fa-link w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("from-url")}</span>
                        </button>
                    {/if}
                </div>
            {/if}
        </div>

        <!-- 4. Library (/trails) -->
        <a
            href="/trails"
            onclick={closeMenus}
            aria-current={activeTab === "library" ? "page" : undefined}
            class="flex flex-col items-center justify-center gap-0.5 px-3 py-1 rounded-2xl transition-colors {activeTab === 'library'
                ? 'text-primary'
                : 'text-content/55 hover:text-content/85'}"
        >
            <i class="fa-solid fa-book-atlas text-[20px] leading-none" aria-hidden="true"></i>
            <span class="text-[11px] font-medium leading-tight">
                {$_("library", { default: "Library" })}
            </span>
        </a>

        <!-- 5. Profile / Theme / Auth -->
        <div class="relative flex items-center justify-center">
            <button
                type="button"
                aria-label={navUser ? "Open user menu" : $_("profile")}
                aria-expanded={profileMenuOpen}
                onclick={() => {
                    createMenuOpen = false;
                    profileMenuOpen = !profileMenuOpen;
                }}
                class="flex flex-col items-center justify-center gap-0.5 px-3 py-1 rounded-2xl cursor-pointer transition-colors {activeTab === 'profile'
                    ? 'text-primary'
                    : 'text-content/55 hover:text-content/85'}"
            >
                {#if navUser}
                    <img
                        class="rounded-full w-6 h-6 object-cover border border-input-border/60"
                        src={getFileURL(navUser, navUser.avatar, "100x100") ||
                            `https://api.dicebear.com/7.x/initials/svg?seed=${navUser.username.toLowerCase()}&backgroundType=gradientLinear`}
                        alt=""
                    />
                {:else}
                    <i class="fa-solid fa-circle-user text-[21px] leading-none" aria-hidden="true"></i>
                {/if}
                <span class="text-[11px] font-medium leading-tight">
                    {$_("profile")}
                </span>
            </button>

            {#if profileMenuOpen}
                <div
                    role="menu"
                    class="absolute bottom-14 right-0 w-52 rounded-2xl bg-menu-background text-content border border-input-border/70 shadow-[0_10px_30px_rgba(0,0,0,0.18)] p-1.5 z-60"
                >
                    {#if navUser}
                        <a
                            href="/profile/@{navUser.username.toLowerCase()}"
                            onclick={closeMenus}
                            class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                        >
                            <i class="fa-solid fa-user w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("profile")}</span>
                        </a>
                        <a
                            href="/profile/@{navUser.username.toLowerCase()}/trails"
                            onclick={closeMenus}
                            class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                        >
                            <i class="fa-solid fa-route w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("my-trails")}</span>
                        </a>
                        <a
                            href="/settings/profile"
                            onclick={closeMenus}
                            class="flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium hover:bg-secondary-hover"
                        >
                            <i class="fa-solid fa-cog w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("settings")}</span>
                        </a>
                    {:else}
                        <button
                            type="button"
                            onclick={() => {
                                closeMenus();
                                void goto("/login");
                            }}
                            class="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium text-left hover:bg-secondary-hover cursor-pointer"
                        >
                            <i class="fa-solid fa-right-to-bracket w-4 text-center text-content/70" aria-hidden="true"></i>
                            <span>{$_("login")}</span>
                        </button>
                    {/if}
                    <div class="border-t border-input-border/50 my-1"></div>
                    <button
                        type="button"
                        onclick={() => {
                            toggleTheme();
                        }}
                        class="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium text-left hover:bg-secondary-hover cursor-pointer"
                    >
                        <i
                            class="fa-regular fa-{$theme === 'light' ? 'moon' : 'sun'} w-4 text-center text-content/70"
                            aria-hidden="true"
                        ></i>
                        <span>
                            {$theme === "light"
                                ? $_("dark-mode", { default: "Dark mode" })
                                : $_("light-mode", { default: "Light mode" })}
                        </span>
                    </button>
                    {#if navUser}
                        <button
                            type="button"
                            onclick={handleLogout}
                            class="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium text-left text-red-500 hover:bg-secondary-hover cursor-pointer"
                        >
                            <i class="fa-solid fa-right-from-bracket w-4 text-center" aria-hidden="true"></i>
                            <span>{$_("logout")}</span>
                        </button>
                    {/if}
                </div>
            {/if}
        </div>
    </div>
</nav>

<UrlImportModal bind:this={urlImportModal}></UrlImportModal>
