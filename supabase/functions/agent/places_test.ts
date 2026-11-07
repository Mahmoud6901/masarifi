import { strict as assert } from 'node:assert';
import { searchPlaces, normalizePlace, haversineKm, priceLabel, AREA_MASK, PLACE_MASK } from './places.ts';
const key='sentinel-private-key';
const area={id:'riyadh',displayName:{text:'Riyadh'},formattedAddress:'Riyadh, Saudi Arabia',types:['locality'],location:{latitude:24.7136,longitude:46.6753}};
const place={id:'cafe',displayName:{text:'Cafe'},formattedAddress:'Olaya',rating:4.5,userRatingCount:123,priceLevel:'PRICE_LEVEL_FREE',currentOpeningHours:{openNow:false},location:area.location,googleMapsUri:'https://maps.google.com/place/cafe'};
function fake(bodies: unknown[], statuses: number[] = []) {
  const calls: Array<{url:string;options:RequestInit}> = [];
  const fetchImpl:typeof fetch=async (url, options)=>{ const i=calls.length; calls.push({url:String(url),options:options!}); return new Response(JSON.stringify(bodies[i]),{status:statuses[i]??200}); };
  return {calls,fetchImpl};
}
const input={query:'family cafe',area:'Riyadh, Saudi Arabia'};
Deno.test('haversine handles known, zero, antipodal and invalid coordinates',()=>{
  assert.equal(haversineKm(area.location,area.location),0);
  assert.ok(Math.abs(haversineKm({latitude:0,longitude:0},{latitude:0,longitude:1})!-111.1949)<0.001);
  assert.ok(Math.abs(haversineKm({latitude:0,longitude:0},{latitude:0,longitude:180})!-20015.0868)<0.001);
  for(const n of [NaN,Infinity,91]) assert.equal(haversineKm({latitude:n,longitude:0},area.location),null);
});
Deno.test('normalization preserves sparse evidence, zero prices, false opening status and ranges',()=>{
  const full=normalizePlace(place,area.location)!;
  assert.equal(full.priceLevel,0);assert.equal(full.priceLabel,'Free');assert.equal(full.openNow,false);assert.equal(full.estimate,true);assert.equal(full.distanceKm,0);assert.equal(full.ratingCount,123);
  const sparse=normalizePlace({displayName:{text:'Sparse'}},area.location)!;
  for(const field of ['address','rating','ratingCount','priceLevel','priceRange','openNow','distanceKm','mapsUrl'] as const) assert.equal(sparse[field],null);
  assert.equal(sparse.priceLabel,'Unknown');assert.equal(priceLabel(4),'Very expensive');
  const ranged=normalizePlace({...place,priceRange:{startPrice:{currencyCode:'KWD',units:'1',nanos:255000000},endPrice:{currencyCode:'KWD',units:'2'}}},area.location)!;
  assert.deepEqual(ranged.priceRange,{startPrice:{currencyCode:'KWD',units:'1',nanos:255000000},endPrice:{currencyCode:'KWD',units:'2',nanos:0}});assert.equal(ranged.estimate,false);
  assert.equal(normalizePlace({...place,rating:Infinity,userRatingCount:-1,priceLevel:'UNKNOWN',location:{latitude:99,longitude:1},googleMapsUri:'javascript:bad'},area.location)!.distanceKm,null);
  assert.equal(normalizePlace({...place,priceRange:{startPrice:{currencyCode:'KWD',units:'2'},endPrice:{currencyCode:'SAR',units:'3'}}},area.location)!.priceRange,null);
});
Deno.test('search entrypoint resolves typed area, sends explicit masks and retains unknown price results',async()=>{
  const f=fake([{places:[area]},{places:[place,{...place,id:'high',priceLevel:'PRICE_LEVEL_EXPENSIVE'},{...place,id:'unknown',priceLevel:'UNKNOWN'}]}]);
  const result=await searchPlaces({...input,max_price_level:0},{apiKey:key,fetchImpl:f.fetchImpl});
  assert.ok('places' in result);assert.deepEqual(result.places!.map(p=>p.id),['cafe','unknown']);
  assert.equal(result.origin!.name,'Riyadh');assert.equal(result.origin!.approximate,true);assert.equal(f.calls.length,2);
  assert.equal(f.calls[0].url,'https://places.googleapis.com/v1/places:searchText');assert.ok(!f.calls[0].url.includes(key));
  assert.deepEqual(JSON.parse(f.calls[0].options.body as string),{textQuery:input.area,pageSize:10});
  assert.deepEqual(JSON.parse(f.calls[1].options.body as string),{textQuery:'family cafe in Riyadh, Saudi Arabia',pageSize:10,locationBias:{circle:{center:area.location,radius:5000}}});
  assert.equal((f.calls[0].options.headers as Record<string,string>)['X-Goog-FieldMask'],AREA_MASK);
  assert.equal((f.calls[1].options.headers as Record<string,string>)['X-Goog-FieldMask'],PLACE_MASK);
  assert.equal((f.calls[1].options.headers as Record<string,string>)['X-Goog-Api-Key'],key);
  assert.equal(AREA_MASK,'places.id,places.displayName,places.formattedAddress,places.types,places.location');
  assert.equal(PLACE_MASK,'places.id,places.displayName,places.formattedAddress,places.rating,places.userRatingCount,places.priceLevel,places.priceRange,places.currentOpeningHours.openNow,places.location,places.googleMapsUri');
});
Deno.test('input/config errors make no request, including missing area and invalid price filters',async()=>{
  const f=fake([]);
  for(const bad of [{query:'x'}, {...input,query:' '},{...input,area:3},{...input,query:'x'.repeat(201)},...[-1,5,1.5,NaN,'1'].map(max_price_level=>({...input,max_price_level}))]) {
    assert.equal((await searchPlaces(bad,{apiKey:key,fetchImpl:f.fetchImpl})).error,'invalid_places_input');
  }
  assert.equal((await searchPlaces(input,{fetchImpl:f.fetchImpl})).error,'places_not_configured');assert.equal(f.calls.length,0);
});
Deno.test('origin failures never search businesses or use IP/coordinate fallback',async()=>{
  for(const [origins,error] of [[[],'area_not_found'],[[place],'area_not_found'],[[{...area,location:{latitude:100,longitude:0}}],'area_not_found'],[[area,{...area,id:'other',location:{latitude:10,longitude:10}}],'area_ambiguous']] as const){
    const f=fake([{places:origins}]); assert.equal((await searchPlaces(input,{apiKey:key,fetchImpl:f.fetchImpl})).error,error);assert.equal(f.calls.length,1);
  }
  const f=fake([{places:[area,{...area,id:'duplicate'}]},{}]);const r=await searchPlaces(input,{apiKey:key,fetchImpl:f.fetchImpl});assert.deepEqual(r.places,[]);assert.equal(f.calls.length,2);
});
Deno.test('HTTP, network, unreadable and malformed errors are bounded and sanitized',async()=>{
  for(const [status,error] of [[401,'places_access_denied'],[403,'places_access_denied'],[429,'places_quota_exceeded'],[500,'places_upstream_error']] as const){
    for(const second of [false,true]) {
      const f=fake(second?[{places:[area]},{secret:key}]:[{secret:key}],second?[200,status]:[status]);const r=await searchPlaces(input,{apiKey:key,fetchImpl:f.fetchImpl});assert.equal(r.error,error);assert.ok(!JSON.stringify(r).includes(key));assert.equal(f.calls.length,second?2:1);
    }
  }
  for(const body of [null,[],{places:'wrong'},{unexpected:'field'}]){const f=fake([body]);assert.equal((await searchPlaces(input,{apiKey:key,fetchImpl:f.fetchImpl})).error,'places_invalid_response');}
  const badJson:typeof fetch=async()=>new Response(key);
  assert.equal((await searchPlaces(input,{apiKey:key,fetchImpl:badJson})).error,'places_invalid_response');
  const offline:typeof fetch=async()=>{throw new Error(key);};const r=await searchPlaces(input,{apiKey:key,fetchImpl:offline});assert.equal(r.error,'places_network_error');assert.ok(!JSON.stringify(r).includes(key));
  const f=fake([{places:[area]},{places:[{id:'broken'}]}]);assert.equal((await searchPlaces(input,{apiKey:key,fetchImpl:f.fetchImpl})).error,'places_invalid_response');
});
Deno.test('timeout aborts even a non-cooperative injected fetch',async()=>{
  let signal:AbortSignal|undefined;
  const fetchImpl:typeof fetch=async(_,opts)=>{signal=opts?.signal ?? undefined;return await new Promise<Response>(()=>{});};
  const result=await searchPlaces(input,{apiKey:key,fetchImpl,timeoutMs:5});assert.equal(result.error,'places_timeout');assert.equal(signal?.aborted,true);
});
