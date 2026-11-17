import { handleError } from '#lib/util/api_util.ts';
import { decodePolyline } from '#lib/util/polyline_util.ts';
import { NavigateRequestSchema } from '#lib/models/api/valhalla_navigate_schema.ts';
import { error, json, type RequestEvent } from '@sveltejs/kit';
import type { NavigateManeuver } from '#lib/models/api/valhalla_navigate_schema.ts';
import { getValhallaUrl } from '#lib/server/valhalla.ts';
import { resolveAcceptLanguage } from '#lib/i18n/locales.ts';
import { synthesizeTrailManeuvers } from '#lib/navigation/trail_maneuver_synthesizer.ts';

const VALHALLA_LANGUAGE_TAGS: Record<string, string> = {
  cs: 'cs-CZ',
  de: 'de-DE',
  en: 'en-US',
  es: 'es-ES',
  fr: 'fr-FR',
  hu: 'hu-HU',
  it: 'it-IT',
  nl: 'nl-NL',
  no: 'nb-NO',
  pl: 'pl-PL',
  pt: 'pt-PT',
  ro: 'ro-RO',
  ru: 'ru-RU',
  zh: 'zh-CN',
};

function toValhallaLanguageTag(locale: string | null | undefined): string {
  const base = locale?.trim().replace('_', '-').split('-')[0]?.toLowerCase() ?? '';
  return VALHALLA_LANGUAGE_TAGS[base] ?? 'en-US';
}

/**
 * @swagger
 * /api/v1/valhalla/navigate:
 *   post:
 *     summary: Get turn-by-turn navigation maneuvers
 *     description: Accepts a trail waypoint array and returns a structured maneuver list with decoded shape points for Flutter navigation
 *     tags:
 *       - Valhalla
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required:
 *               - shape
 *             properties:
 *               shape:
 *                 type: array
 *                 minItems: 2
 *                 maxItems: 500
 *                 items:
 *                   type: object
 *                   required: [lat, lon]
 *                   properties:
 *                     lat:
 *                       type: number
 *                       minimum: -90
 *                       maximum: 90
 *                     lon:
 *                       type: number
 *                       minimum: -180
 *                       maximum: 180
 *               costing:
 *                 type: string
 *                 enum: [pedestrian, bicycle]
 *                 default: pedestrian
 *     responses:
 *       200:
 *         description: Maneuver list and decoded shape points
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 maneuvers:
 *                   type: array
 *                   items:
 *                     type: object
 *                     properties:
 *                       instruction:
 *                         type: string
 *                       length:
 *                         type: number
 *                       begin_shape_index:
 *                         type: integer
 *                       bearing:
 *                         type: number
 *                 shape:
 *                   type: array
 *                   items:
 *                     type: array
 *                     items:
 *                       type: number
 *       400:
 *         description: Invalid request body or missing VALHALLA_URL
 *       401:
 *         description: Unauthorized
 *       502:
 *         description: Valhalla upstream error
 */
export async function POST(event: RequestEvent) {
  if (!event.locals.user) {
    return error(401, "Unauthorized");
  }

  try {
    const body = NavigateRequestSchema.parse(await event.request.json());

    const rawLocale =
      body.language ||
      event.locals.settings?.language ||
      resolveAcceptLanguage(event.request.headers.get('accept-language'));

    // Check the base before appending the path: null + '/trace_route' would be the
    // truthy string "null/trace_route".
    const valhallaUrl = getValhallaUrl();
    if (!valhallaUrl) {
      return json(synthesizeTrailManeuvers(body.shape, { locale: rawLocale }));
    }

    const navigateUrl = valhallaUrl + '/trace_route';
    const valhallaReq = {
      shape: body.shape,
      costing: body.costing,
      directions_type: "instructions",
      directions_options: {
        language: toValhallaLanguageTag(rawLocale),
      },
      shape_match: "map_snap",
    };

    try {
      const res = await event.fetch(navigateUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(valhallaReq),
      });

      if (!res.ok) {
        return json(synthesizeTrailManeuvers(body.shape, { locale: rawLocale }));
      }

      const data = await res.json();
      const trip = data?.trip;
      if (!trip?.legs) {
        return json(synthesizeTrailManeuvers(body.shape, { locale: rawLocale }));
      }

      const shape: [number, number][] = [];
      const maneuvers: NavigateManeuver[] = [];

      for (const leg of trip.legs) {
        const offset = shape.length;

        for (const [lng, lat] of decodePolyline(leg.shape)) {
          shape.push([lat, lng]);
        }

        for (const m of leg.maneuvers ?? []) {
          maneuvers.push({
            instruction: m.instruction,
            length: m.length,
            begin_shape_index: offset + m.begin_shape_index,
            bearing: m.bearing_after ?? m.bearing_before ?? 0,
            type: m.type ?? 0,
          });
        }
      }

      if (maneuvers.length === 0 || shape.length === 0) {
        return json(synthesizeTrailManeuvers(body.shape, { locale: rawLocale }));
      }

      return json({ maneuvers, shape });
    } catch {
      return json(synthesizeTrailManeuvers(body.shape, { locale: rawLocale }));
    }
  } catch (e: any) {
    return handleError(e);
  }
}
