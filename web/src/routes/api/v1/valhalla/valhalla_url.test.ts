import type { RequestEvent } from '@sveltejs/kit';
import { describe, expect, it, vi } from 'vitest';

vi.mock('#lib/server/valhalla.ts', () => ({ getValhallaUrl: () => null }));

import { POST as height } from './height/+server';
import { POST as navigate } from './navigate/+server';
import { POST as route } from './route/+server';
import { POST as traceRoute } from './trace-route/+server';

function event(body: unknown): RequestEvent {
    return {
        request: new Request('http://localhost/api/v1/valhalla', { method: 'POST', body: JSON.stringify(body) }),
        locals: { pb: { authStore: { record: { id: 'user' }, token: 't' } }, user: { id: 'user' } },
        fetch: vi.fn(),
    } as unknown as RequestEvent;
}

describe('Valhalla routes without VALHALLA_URL', () => {
    const shape = { shape: [{ lat: 47, lon: 11 }, { lat: 47.01, lon: 11.01 }], costing: 'pedestrian' };

    it.each([
        ['route', route, { locations: shape.shape, costing: 'pedestrian' }],
        ['height', height, { shape: shape.shape }],
        ['trace-route', traceRoute, shape],
    ])('%s answers 400 instead of calling a "null/..." URL', async (_name, handler, body) => {
        const e = event(body);

        const response = await handler(e);

        expect(response.status).toBe(400);
        expect(await response.json()).toEqual({ message: 'VALHALLA_URL not set' });
        expect(e.fetch).not.toHaveBeenCalled();
    });

    it('navigate returns 200 with synthesized fallback maneuvers instead of calling a "null/..." URL', async () => {
        const e = event(shape);

        const response = await navigate(e);

        expect(response.status).toBe(200);
        const body = await response.json();
        expect(Array.isArray(body.maneuvers)).toBe(true);
        expect(body.maneuvers.length).toBeGreaterThanOrEqual(2);
        expect(body.shape).toEqual([
            [47, 11],
            [47.01, 11.01],
        ]);
        expect(e.fetch).not.toHaveBeenCalled();
    });
});
