// Pure Places adapter: callers supply secrets and tests supply fetch.
export interface Point { latitude: number; longitude: number }
type Obj = Record<string, unknown>;
const object = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const text = (v: unknown): string | null => typeof v === 'string' && v.trim() ? v.trim() : null;
function point(v: unknown): Point | null {
  if (!object(v)) return null;
  const {latitude, longitude} = v;
  return typeof latitude === 'number' && Number.isFinite(latitude) && Math.abs(latitude) <= 90 && typeof longitude === 'number' && Number.isFinite(longitude) && Math.abs(longitude) <= 180 ? {latitude, longitude} : null;
}
export function haversineKm(a: Point, b: Point): number | null {
  if (!point(a) || !point(b)) return null;
  const rad = (n: number) => n * Math.PI / 180;
  const h = Math.sin(rad(b.latitude-a.latitude)/2)**2 + Math.cos(rad(a.latitude))*Math.cos(rad(b.latitude))*Math.sin(rad(b.longitude-a.longitude)/2)**2;
  return 6371 * 2 * Math.asin(Math.sqrt(Math.max(0, Math.min(1, h))));
}
const LEVELS: Record<string, number> = {PRICE_LEVEL_FREE:0, PRICE_LEVEL_INEXPENSIVE:1, PRICE_LEVEL_MODERATE:2, PRICE_LEVEL_EXPENSIVE:3, PRICE_LEVEL_VERY_EXPENSIVE:4};
export const priceLabel = (level: number | null): string => level === null ? 'Unknown' : ['Free', 'Inexpensive', 'Moderate', 'Expensive', 'Very expensive'][level] ?? 'Unknown';
function money(v: unknown) {
  if (!object(v) || typeof v.currencyCode !== 'string' || !/^[A-Z]{3}$/.test(v.currencyCode)) return null;
  const units = v.units ?? '0';
  const nanos = v.nanos ?? 0;
  if (typeof units !== 'string' || !/^\d{1,19}$/.test(units) || BigInt(units) > 9223372036854775807n || typeof nanos !== 'number' || !Number.isInteger(nanos) || nanos < 0 || nanos > 999999999) return null;
  return {currencyCode:v.currencyCode, units, nanos};
}
function range(v: unknown) {
  if (!object(v)) return null;
  const startPrice = money(v.startPrice), endPrice = money(v.endPrice);
  if ((!startPrice && !endPrice) || (v.startPrice != null && !startPrice) || (v.endPrice != null && !endPrice)) return null;
  if (startPrice && endPrice && (startPrice.currencyCode !== endPrice.currencyCode || BigInt(startPrice.units)*1000000000n+BigInt(startPrice.nanos) > BigInt(endPrice.units)*1000000000n+BigInt(endPrice.nanos))) return null;
  return {startPrice, endPrice};
}
export function normalizePlace(p: unknown, origin: Point) {
  if (!object(p)) return null;
  const name = object(p.displayName) ? text(p.displayName.text) : null;
  if (!name) return null;
  const level = typeof p.priceLevel === 'string' ? LEVELS[p.priceLevel] ?? null : null;
  const priceRange = range(p.priceRange);
  const loc = point(p.location);
  const distance = loc ? haversineKm(origin, loc) : null;
  const rating = typeof p.rating === 'number' && Number.isFinite(p.rating) && p.rating >= 0 && p.rating <= 5 ? p.rating : null;
  const ratingCount = typeof p.userRatingCount === 'number' && Number.isSafeInteger(p.userRatingCount) && p.userRatingCount >= 0 ? p.userRatingCount : null;
  const uri = text(p.googleMapsUri);
  const mapsUrl = uri && /^https:\/\/(?:www\.)?(?:google\.com|maps\.google\.com|maps\.app\.goo\.gl)\//.test(uri) ? uri : null;
  return {id:text(p.id), name, address:text(p.formattedAddress), rating, ratingCount, priceLevel:level, priceLabel:priceLabel(level), priceRange, estimate:priceRange === null && level !== null, openNow:object(p.currentOpeningHours) && typeof p.currentOpeningHours.openNow === 'boolean' ? p.currentOpeningHours.openNow : null, distanceKm:distance === null ? null : Math.round(distance*100)/100, mapsUrl};
}
export const AREA_MASK = 'places.id,places.displayName,places.formattedAddress,places.types,places.location';
export const PLACE_MASK = 'places.id,places.displayName,places.formattedAddress,places.rating,places.userRatingCount,places.priceLevel,places.priceRange,places.currentOpeningHours.openNow,places.location,places.googleMapsUri';
const ENDPOINT = 'https://places.googleapis.com/v1/places:searchText';
class PlacesFailure extends Error { readonly code: string; constructor(code: string, message: string) { super(message); this.code = code; } }
function failure(code: string, message: string): never { throw new PlacesFailure(code,message); }
const geographic = (v: unknown) => Array.isArray(v) && v.some(t => typeof t === 'string' && /^(?:locality|sublocality(?:_level_[1-5])?|neighborhood|administrative_area_level_[1-7]|postal_code|country)$/.test(t));
export async function searchPlaces(input: Record<string, unknown>, options: {apiKey?:string;fetchImpl?:typeof fetch;timeoutMs?:number}) {
  const query = text(input.query), area = text(input.area), max = input.max_price_level;
  if (!query || !area || query.length > 200 || area.length > 200 || (max !== undefined && (typeof max !== 'number' || !Number.isInteger(max) || max < 0 || max > 4))) return {error:'invalid_places_input',message:'Provide a need, a city/area (up to 200 characters each), and an optional price level 0–4.'};
  if (!options.apiKey?.trim()) return {error:'places_not_configured',message:'Place search is unavailable. Please try again later.'};
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Number.isFinite(options.timeoutMs) && options.timeoutMs! > 0 ? Math.min(options.timeoutMs!, 15000) : 8000;
  async function request(body: Obj, mask: string): Promise<unknown[]> {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    // Race as well as abort so even a non-cooperative transport is bounded.
    const operation = async () => {
      const response = await fetchImpl(ENDPOINT, {method:'POST',headers:{'content-type':'application/json','X-Goog-Api-Key':options.apiKey!, 'X-Goog-FieldMask':mask},body:JSON.stringify(body),signal:controller.signal});
      if (!response.ok) {
        if (response.status === 429) failure('places_quota_exceeded','Place search is temporarily rate limited. Try again later.');
        if (response.status === 401 || response.status === 403) failure('places_access_denied','Place search is unavailable. Please try again later.');
        failure('places_upstream_error','The place provider could not complete the search. Try again.');
      }
      const data: unknown = await response.json();
      if (!object(data) || (data.places !== undefined && !Array.isArray(data.places))) failure('places_invalid_response','The place provider returned an unreadable response. Try again.');
      if (data.places === undefined && Object.keys(data).length !== 0) failure('places_invalid_response','The place provider returned an unreadable response. Try again.');
      return (data.places ?? []) as unknown[];
    };
    try {
      return await Promise.race([operation(),new Promise<never>((_,reject)=> { timer=setTimeout(()=>{controller.abort();reject(new PlacesFailure('places_timeout','Place search timed out. Try again.'));},timeoutMs); })]);
    } catch (e) {
      if (e instanceof PlacesFailure) throw e;
      if (e instanceof SyntaxError) failure('places_invalid_response','The place provider returned an unreadable response. Try again.');
      failure('places_network_error','Could not connect to the place provider. Try again.');
    } finally { clearTimeout(timer); }
  }
  try {
    const areas = await request({textQuery:area,pageSize:10},AREA_MASK);
    const candidates: Array<{name:string;address:string|null;latitude:number;longitude:number}> = [];
    for (const p of areas) {
      if (!object(p) || !geographic(p.types)) continue;
      const loc=point(p.location), name=object(p.displayName) ? text(p.displayName.text) : null;
      if (!loc || !name) continue;
      // Several IDs at effectively the same centre do not create a new origin.
      if (!candidates.some(c=>haversineKm(c,loc)! < 0.1)) candidates.push({name,address:text(p.formattedAddress),...loc});
    }
    if (candidates.length === 0) failure('area_not_found','Could not resolve that area. Specify a city, area and country.');
    if (candidates.length !== 1) failure('area_ambiguous','That area has several matches. Specify a city, area and country.');
    const origin = {query:area,...candidates[0],approximate:true};
    const rows = await request({textQuery:`${query} in ${area}`,pageSize:10,locationBias:{circle:{center:{latitude:origin.latitude,longitude:origin.longitude},radius:5000}}},PLACE_MASK);
    const normalized = rows.map(p=>normalizePlace(p,origin));
    if (rows.length && normalized.every(p=>p===null)) failure('places_invalid_response','The place provider returned an unreadable response. Try again.');
    const places=normalized.filter((p):p is NonNullable<typeof p>=>p!==null).filter(p=>max === undefined || p.priceLevel === null || p.priceLevel <= (max as number)).slice(0,10);
    return {origin,places};
  } catch(e) {
    if (e instanceof PlacesFailure) return {error:e.code,message:e.message};
    return {error:'places_unavailable',message:'Place search is unavailable. Try again.'};
  }
}
