// Preserve published MkDocs anchors while letting Starlight build its outline.
// The Python generator appends explicit IDs to every heading outside code blocks.
export default function scribeHeadingIds() {
  return (tree) => {
    function visit(node) {
      if (node.type === 'heading') {
        const tail = node.children?.at(-1);
        const match = tail?.type === 'text' && tail.value.match(/\s*\{#([\w-]+)\}\s*$/);
        if (match) {
          tail.value = tail.value.slice(0, match.index);
          node.data ??= {};
          node.data.hProperties ??= {};
          node.data.hProperties.id = match[1];
        }
      }
      for (const child of node.children ?? []) visit(child);
    }
    visit(tree);
  };
}
