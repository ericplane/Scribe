import assert from 'node:assert/strict';
import test from 'node:test';
import scribeHeadingIds from './starlight-headings.mjs';

test('keeps API member anchors in heading properties without visible attribute text', () => {
  const heading = {type: 'heading', depth: 3, children: [{type: 'text', value: '.Get {#get}'}]};
  scribeHeadingIds()({type: 'root', children: [heading]});
  assert.equal(heading.data.hProperties.id, 'get');
  assert.equal(heading.children[0].value, '.Get');
});

test('retains inline code and existing properties while using the generated anchor', () => {
  const heading = {type: 'heading', depth: 2, data: {hProperties: {className: ['example']}}, children: [
    {type: 'text', value: 'Using '}, {type: 'inlineCode', value: 'Scribe.Big'}, {type: 'text', value: ' {#using-scribebig}'},
  ]};
  scribeHeadingIds()({type: 'root', children: [heading]});
  assert.deepEqual(heading.data.hProperties, {className: ['example'], id: 'using-scribebig'});
  assert.equal(heading.children[1].value, 'Scribe.Big');
});

test('ignores heading-looking text inside code and ordinary paragraphs', () => {
  const tree = {type: 'root', children: [{type: 'code', value: '## Example {#keep}'},
    {type: 'paragraph', children: [{type: 'text', value: 'A literal {#keep}'}]}]};
  const original = structuredClone(tree);
  scribeHeadingIds()(tree);
  assert.deepEqual(tree, original);
});
