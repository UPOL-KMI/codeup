// Page.js (src/components/layout/Page/Page.js) accepts a `resourceArray` prop
// (used by several pages, e.g. Instances/InstancesManagement, to pass a Map of
// list-type resources), but its render() only ever destructures/forwards
// `resource` to the underlying <ResourceRenderer> -- `resourceArray` silently
// falls into the `...props` rest and is dropped. ResourceRenderer.getResources()
// then sees neither prop set, returns null, and render()'s `stillLoading` check
// starts with `!resources` -- true forever, regardless of what's actually in the
// Redux store. Any page passing ONLY resourceArray (no resource) to <Page> is
// permanently stuck on the loading spinner even though its data fetch succeeds.
// Pages that pass `resource` at the top level and use a separate, directly
// nested <ResourceRenderer resourceArray={...}> for secondary lists (the more
// common pattern) are unaffected, which is why most of the app works fine.
import fs from 'fs';

const file = 'src/components/layout/Page/Page.js';
const contents = fs.readFileSync(file, 'utf8');

const oldDestructure = '      resource,\n      forceLoading = false,';
const newDestructure = '      resource,\n      resourceArray,\n      forceLoading = false,';

const oldJsx = '      <ResourceRenderer\n        resource={resource}\n        forceLoading={forceLoading}';
const newJsx = '      <ResourceRenderer\n        resource={resource}\n        resourceArray={resourceArray}\n        forceLoading={forceLoading}';

if (!contents.includes(oldDestructure) || !contents.includes(oldJsx)) {
  throw new Error('patch-compatibility: Page.js no longer matches the expected upstream text -- check if this patch is still needed.');
}

const patched = contents.replace(oldDestructure, newDestructure).replace(oldJsx, newJsx);
fs.writeFileSync(file, patched);
console.error('patch-compatibility: Page.js now forwards resourceArray to ResourceRenderer.');
