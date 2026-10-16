#!/usr/bin/env node
// Pushes the App Store listing in store/app-store/ to App Store Connect, for
// the app with bundle ID com.nu01.presence: per locale (one folder each, e.g.
// en-US/) the name, subtitle and privacy policy URL, and the editable
// version's description, keywords, promotional text, support and marketing
// URLs; the categories, content rights, copyright and age rating.
//
//   ASC_KEY_ID=... ASC_ISSUER_ID=... node scripts/app-store-listing.mjs [version]
//
// The API key is read from ASC_KEY_PATH, by default
// ../setec-astronomy/presence.nu01/env.local/apple/AuthKey_<ASC_KEY_ID>.p8.
// With a version (e.g. 0.6.202610151308), the editable version is renamed to
// it, to match the build's CFBundleShortVersionString. DRY_RUN=1 only prints.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { createSign } from 'node:crypto';
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
