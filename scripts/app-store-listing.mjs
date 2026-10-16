#!/usr/bin/env node
// Pushes the App Store listing in store/app-store/ to App Store Connect, for
// the app with bundle ID com.nu01.presence: per locale (one folder each, e.g.
// en-US/) the name, subtitle and privacy policy URL, and the editable
// version's description, keywords, promotional text, support and marketing
// URLs, and its 6.9" iPhone screenshots (screenshots/*.png, in name order);
// the categories, content rights, copyright and age rating; and each
// Premium subscription's review screenshot (subscription-review.png).
//
//   ASC_KEY_ID=... ASC_ISSUER_ID=... node scripts/app-store-listing.mjs [version]
//
// The API key is read from ASC_KEY_PATH, by default
// ../setec-astronomy/presence.nu01/env.local/apple/AuthKey_<ASC_KEY_ID>.p8.
// With a version (e.g. 0.6.202610151308), the editable version is renamed to
// it, to match the build's CFBundleShortVersionString. DRY_RUN=1 only prints.
// SCREENSHOTS_ONLY=1 uploads the screenshots and nothing else. Screenshots
// already there with the same files (by MD5) are kept, so it can run again.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { createHash, createSign } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const listing = join(repo, 'store/app-store');
const bundleId = 'com.nu01.presence';
const editable = ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'];

const kid = process.env.ASC_KEY_ID;
const iss = process.env.ASC_ISSUER_ID;
if (!/^[A-Z0-9]{10}$/.test(kid ?? '') || !iss) {
  console.error('error: set ASC_KEY_ID (10 characters) and ASC_ISSUER_ID');
  process.exit(2);
}
const keyPath = process.env.ASC_KEY_PATH ??
  join(repo, '../setec-astronomy/presence.nu01/env.local/apple', `AuthKey_${kid}.p8`);
const key = readFileSync(keyPath, 'utf8');
const dry = process.env.DRY_RUN === '1';
const screenshotsOnly = process.env.SCREENSHOTS_ONLY === '1';
const version = process.argv[2];

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid, typ: 'JWT' });
  const body = b64({ iss, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
  const sig = createSign('SHA256').update(`${head}.${body}`)
    .sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${head}.${body}.${sig}`;
}

async function api(method, path, data) {
  if (dry && method !== 'GET') {
    console.log(`dry run: ${method} ${path} ${JSON.stringify(data?.data?.attributes ?? data?.data?.relationships ?? {})}`);
    return {};
  }
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: data && JSON.stringify(data),
  });
  const json = res.status === 204 ? {} : await res.json();
  if (!res.ok) {
    const why = (json.errors ?? []).map((e) => e.detail ?? e.title).join('; ');
    throw new Error(`${method} ${path}: ${res.status} ${why}`);
  }
  return json;
}

const read = (dir, name) => {
  const f = join(dir, name);
  return existsSync(f) ? readFileSync(f, 'utf8').trim() : undefined;
};
const defined = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));

const app = (await api('GET', `/v1/apps?filter[bundleId]=${bundleId}`)).data
  .find((a) => a.attributes.bundleId === bundleId);
if (!app) throw new Error(`no app for ${bundleId} in App Store Connect`);
console.log(`app ${app.id} (${app.attributes.name})`);

const info = (await api('GET', `/v1/apps/${app.id}/appInfos`)).data
  .find((i) => editable.includes(i.attributes.appStoreState ?? i.attributes.state));
if (!info) throw new Error('no editable app info (is a version in review?)');

const versions = (await api('GET',
  `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&filter[appStoreState]=${editable.join(',')}`)).data;
if (versions.length !== 1) throw new Error(`expected one editable iOS version, found ${versions.length}`);
const ver = versions[0];

const locales = readdirSync(listing).filter((d) => statSync(join(listing, d)).isDirectory());
const infoLocs = (await api('GET', `/v1/appInfos/${info.id}/appInfoLocalizations`)).data;
const verLocs = (await api('GET', `/v1/appStoreVersions/${ver.id}/appStoreVersionLocalizations`)).data;

// The listing's text, categories, rights and age rating.
async function setListing() {
  for (const locale of locales) {
    const dir = join(listing, locale);
    const infoAttrs = defined({
      name: read(dir, 'name.txt'),
      subtitle: read(dir, 'subtitle.txt'),
      privacyPolicyUrl: read(dir, 'privacy_url.txt'),
    });
    const verAttrs = defined({
      description: read(dir, 'description.txt'),
      keywords: read(dir, 'keywords.txt'),
      promotionalText: read(dir, 'promotional_text.txt'),
      supportUrl: read(dir, 'support_url.txt'),
      marketingUrl: read(dir, 'marketing_url.txt'),
    });
    const il = infoLocs.find((l) => l.attributes.locale === locale);
    await (il
      ? api('PATCH', `/v1/appInfoLocalizations/${il.id}`,
        { data: { type: 'appInfoLocalizations', id: il.id, attributes: infoAttrs } })
      : api('POST', '/v1/appInfoLocalizations', { data: {
        type: 'appInfoLocalizations', attributes: { locale, ...infoAttrs },
        relationships: { appInfo: { data: { type: 'appInfos', id: info.id } } } } }));
    const vl = verLocs.find((l) => l.attributes.locale === locale);
    await (vl
      ? api('PATCH', `/v1/appStoreVersionLocalizations/${vl.id}`,
        { data: { type: 'appStoreVersionLocalizations', id: vl.id, attributes: verAttrs } })
      : api('POST', '/v1/appStoreVersionLocalizations', { data: {
        type: 'appStoreVersionLocalizations', attributes: { locale, ...verAttrs },
        relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: ver.id } } } } }));
    console.log(`${locale}: listing set`);
  }

  await api('PATCH', `/v1/appInfos/${info.id}`, { data: { type: 'appInfos', id: info.id, relationships: {
    primaryCategory: { data: { type: 'appCategories', id: 'PHOTO_AND_VIDEO' } },
    secondaryCategory: { data: { type: 'appCategories', id: 'UTILITIES' } },
  } } });
  await api('PATCH', `/v1/apps/${app.id}`, { data: { type: 'apps', id: app.id,
    attributes: { contentRightsDeclaration: 'DOES_NOT_USE_THIRD_PARTY_CONTENT' } } });
  await api('PATCH', `/v1/appStoreVersions/${ver.id}`, { data: { type: 'appStoreVersions', id: ver.id,
    attributes: defined({ copyright: read(listing, 'copyright.txt'), versionString: version }) } });
  console.log(`version ${version ?? ver.attributes.versionString}: copyright set; categories and content rights set`);

  const rating = (await api('GET', `/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
  await api('PATCH', `/v1/ageRatingDeclarations/${rating.id}`, { data: {
    type: 'ageRatingDeclarations', id: rating.id,
    attributes: JSON.parse(readFileSync(join(listing, 'age-rating.json'), 'utf8')) } });
  console.log('age rating set');
}
if (!screenshotsOnly) await setListing();


// Screenshots. The 6.9" iPhone slot is APP_IPHONE_67 in the API (it takes
// 1320x2868 and 1290x2796); the App Store scales it down for the smaller
// iPhones. iPhone only, so no iPad screenshots.
const iphoneSlot = 'APP_IPHONE_67';
const md5 = (file) => createHash('md5').update(readFileSync(file)).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Reserves an asset (POST), uploads its bytes as Apple's upload operations
// say, and commits it (PATCH uploaded, with the file's MD5).
async function upload(type, file, relationships) {
  const bytes = readFileSync(file);
  const fileName = file.split('/').pop();
  if (dry) {
    console.log(`dry run: upload ${fileName} as ${type}`);
    return undefined;
  }
  const made = (await api('POST', `/v1/${type}`, { data: { type,
    attributes: { fileName, fileSize: bytes.length }, relationships } })).data;
  for (const op of made.attributes.uploadOperations) {
    const res = await fetch(op.url, {
      method: op.method,
      headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])),
      body: bytes.subarray(op.offset, op.offset + op.length),
    });
    if (!res.ok) throw new Error(`upload of ${fileName}: ${res.status} ${await res.text()}`);
  }
  await api('PATCH', `/v1/${type}/${made.id}`, { data: { type, id: made.id,
    attributes: { uploaded: true, sourceFileChecksum: md5(file) } } });
  return made.id;
}

// Waits for Apple to process uploads; returns each one's final state.
async function delivered(type, ids) {
  const states = {};
  for (const id of ids) {
    for (let i = 0; i < 60; i++) {
      const a = (await api('GET', `/v1/${type}/${id}`)).data.attributes;
      states[id] = a.assetDeliveryState?.state;
      if (states[id] === 'FAILED') {
        console.error(`${a.fileName}: ${JSON.stringify(a.assetDeliveryState.errors)}`);
      }
      if (['COMPLETE', 'FAILED'].includes(states[id])) break;
      await sleep(5000);
    }
  }
  return states;
}

// Per locale, screenshots/*.png in name order replace the 6.9" set, unless
// it already has exactly these files.
for (const locale of locales) {
  const dir = join(listing, locale, 'screenshots');
  if (!existsSync(dir)) continue;
  const files = readdirSync(dir).filter((f) => f.endsWith('.png')).sort().map((f) => join(dir, f));
  if (!files.length) continue;
  const vl = (await api('GET', `/v1/appStoreVersions/${ver.id}/appStoreVersionLocalizations`)).data
    .find((l) => l.attributes.locale === locale);
  if (!vl) throw new Error(`${locale}: no version localization for the screenshots`);
  const sets = (await api('GET', `/v1/appStoreVersionLocalizations/${vl.id}/appScreenshotSets`)).data;
  let set = sets.find((s) => s.attributes.screenshotDisplayType === iphoneSlot);
  const have = set ? (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data : [];
  const same = have.length === files.length && have.every((s, i) =>
    s.attributes.sourceFileChecksum === md5(files[i]) &&
    s.attributes.assetDeliveryState?.state === 'COMPLETE');
  if (same) {
    console.log(`${locale}: the ${files.length} screenshots are already there`);
    continue;
  }
  set ??= (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets',
    attributes: { screenshotDisplayType: iphoneSlot },
    relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: vl.id } } } } })).data;
  for (const old of have) await api('DELETE', `/v1/appScreenshots/${old.id}`);
  const ids = [];
  for (const file of files) {
    ids.push(await upload('appScreenshots', file,
      { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set?.id } } }));
  }
  if (dry) continue;
  await api('PATCH', `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`,
    { data: ids.map((id) => ({ type: 'appScreenshots', id })) });
  const states = await delivered('appScreenshots', ids);
  files.forEach((f, i) => console.log(`${locale}: ${f.split('/').pop()} ${states[ids[i]]}`));
  if (Object.values(states).some((s) => s !== 'COMPLETE')) process.exitCode = 1;
}

// Each subscription's review screenshot: the Premium purchase screen.
const review = join(listing, 'subscription-review.png');
if (existsSync(review)) {
  const groups = await api('GET',
    `/v1/apps/${app.id}/subscriptionGroups?include=subscriptions&limit[subscriptions]=50`);
  const subs = (groups.included ?? []).filter((i) => i.type === 'subscriptions');
  for (const sub of subs) {
    const name = sub.attributes.productId;
    const old = (await api('GET', `/v1/subscriptions/${sub.id}/appStoreReviewScreenshot`)).data;
    if (old?.attributes.sourceFileChecksum === md5(review) &&
        old.attributes.assetDeliveryState?.state === 'COMPLETE') {
      console.log(`${name}: the review screenshot is already there`);
      continue;
    }
    if (old) await api('DELETE', `/v1/subscriptionAppStoreReviewScreenshots/${old.id}`);
    const id = await upload('subscriptionAppStoreReviewScreenshots', review,
      { subscription: { data: { type: 'subscriptions', id: sub.id } } });
    if (dry) continue;
    const state = (await delivered('subscriptionAppStoreReviewScreenshots', [id]))[id];
    console.log(`${name}: review screenshot ${state}`);
    if (state !== 'COMPLETE') process.exitCode = 1;
  }
}
