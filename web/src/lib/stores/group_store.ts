import { get, writable } from "svelte/store";
import {
    createLiveGroup,
    fetchLiveGroup,
    getSavedGroupSession,
    joinLiveGroup,
    leaveLiveGroup,
    normalizeGroupCode,
    type GroupSessionDto,
} from "#lib/live/live_client.ts";

export const activeGroupSession = writable<GroupSessionDto | null>(null);
export const activeGroupBusy = writable<boolean>(false);
export const groupSheetOpen = writable<boolean>(false);
export const groupSheetTrailId = writable<string | undefined>(undefined);
export const groupSheetTrailName = writable<string>("");
export const groupSheetInitialCode = writable<string>("");

let restoredOnce = false;

export async function restoreSharedGroupSession(trailId?: string): Promise<GroupSessionDto | null> {
    if (typeof window === "undefined") return null;
    if (get(activeGroupSession)) return get(activeGroupSession);
    if (restoredOnce) return null;
    restoredOnce = true;
    const saved = getSavedGroupSession(trailId);
    if (!saved?.code) return null;
    const loaded = await fetchLiveGroup(saved.code);
    if (loaded) {
        activeGroupSession.set(loaded);
    }
    return loaded;
}

export async function createSharedGroup(
    displayName: string,
    trailId?: string,
): Promise<GroupSessionDto | null> {
    activeGroupBusy.set(true);
    try {
        const created = await createLiveGroup({ displayName, trailId });
        if (created) {
            activeGroupSession.set(created);
        }
        return created;
    } finally {
        activeGroupBusy.set(false);
    }
}

export async function joinSharedGroup(
    code: string,
    displayName: string,
    trailId?: string,
): Promise<GroupSessionDto | null> {
    activeGroupBusy.set(true);
    try {
        const joined = await joinLiveGroup(code, { displayName, trailId });
        if (joined) {
            activeGroupSession.set(joined);
        }
        return joined;
    } finally {
        activeGroupBusy.set(false);
    }
}

export async function leaveSharedGroup(): Promise<void> {
    const current = get(activeGroupSession);
    activeGroupBusy.set(true);
    try {
        if (current?.code) {
            await leaveLiveGroup(current.code);
        }
        activeGroupSession.set(null);
    } finally {
        activeGroupBusy.set(false);
    }
}

export function openSharedGroupSheet(opts?: {
    trailId?: string;
    trailName?: string;
    joinCode?: string | null;
}): void {
    groupSheetTrailId.set(opts?.trailId);
    groupSheetTrailName.set(opts?.trailName ?? "");
    const cleanCode = normalizeGroupCode(opts?.joinCode ?? "");
    groupSheetInitialCode.set(cleanCode ?? "");
    groupSheetOpen.set(true);
    void restoreSharedGroupSession(opts?.trailId);
}
