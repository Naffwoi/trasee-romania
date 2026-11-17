import { browser } from '$app/env';
import { getPb } from '#lib/pocketbase.ts';
import { init, register } from 'svelte-i18n';
import {
    defaultLocale,
    LOCALE_LOADERS,
    normalizeLocale,
    resolveNavigatorLocale,
} from './locales';

for (const [localeKey, loader] of Object.entries(LOCALE_LOADERS)) {
    register(localeKey, loader)
}

const userLang = browser ? getPb().authStore.record?.language : null;

const initial = userLang
    ? normalizeLocale(userLang)
    : browser
        ? resolveNavigatorLocale(window.navigator.languages, window.navigator.language)
        : defaultLocale;

init({
    fallbackLocale: defaultLocale,
    initialLocale: initial,
    formats: {
        date: {
            monthName: { month: 'long' }
        },
        number: {},
        time: {}
    },
})
