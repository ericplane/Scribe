import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { unified } from '@astrojs/markdown-remark';
import scribeHeadings from '../docgen/starlight-headings.mjs';
import { dark, light, styleOverrides } from './src/code-theme.mjs';

// GitHub Pages serves this custom domain at /, without the repository prefix.
const SITE = 'https://scribe.ericplane.dev';

export default defineConfig({
  site: SITE,
  trailingSlash: 'always',
  outDir: './dist',
  markdown: { processor: unified({ remarkPlugins: [scribeHeadings] }) },
  integrations: [starlight({
    title: 'Scribe',
    disable404Route: true,
    description: 'Persistent, typed, auto-replicated player data for Roblox. Learn the basics, build a feature, or explore the API.',
    favicon: '/assets/favicon.png',
    head: [
      { tag: 'meta', attrs: { property: 'og:image', content: `${SITE}/assets/social-card.png` } },
      { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
      { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
      { tag: 'meta', attrs: { property: 'og:image:alt', content: 'Scribe: player data, without the plumbing' } },
      { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
      { tag: 'meta', attrs: { name: 'twitter:image', content: `${SITE}/assets/social-card.png` } },
    ],
    customCss: ['./src/styles/scribe.css'],
    components: {
      SiteTitle: './src/components/SiteTitle.astro',
      PageTitle: './src/components/PageTitle.astro',
    },
    social: [{ icon: 'github', label: 'Scribe on GitHub', href: 'https://github.com/ericplane/Scribe' }],
    tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    expressiveCode: { themes: [dark, light], styleOverrides },
    sidebar: [
      { label: 'Start here', items: [
        { label: 'Your first player data', slug: 'getting-started' },
        { label: 'Declare your template', slug: 'templates' },
        { label: 'Read and write values', slug: 'values' },
        { label: 'Test modes and real saving', slug: 'testing' },
        { label: 'The Emberfall example', slug: 'emberfall' },
      ] },
      { label: 'Build something', collapsed: true, items: [
        { label: 'Find a recipe', slug: 'recipes' },
        'containers', 'datatypes', 'big-numbers', 'time', 'derived', 'server-store',
        'commands', 'ui-frameworks', 'monetization', 'gifting', 'exchange', 'economy',
        'leaderboards', 'telemetry',
      ] },
      { label: 'Understand Scribe', collapsed: true, items: [
        'lifecycle', 'visibility', 'transactions', 'transports', 'security', 'cost',
      ] },
      { label: 'Manage your game', collapsed: true, items: ['studio-plugin', 'profiles', 'migrating'] },
      { label: 'Reference', collapsed: true, items: [
        { label: 'Find the right API', slug: 'reference' },
        'configuration', 'log-codes', 'changelog',
        { label: 'Scribe', slug: 'api/scribe' },
        { label: 'Server', slug: 'api/server' },
        { label: 'Client', slug: 'api/client' },
        { label: 'Value', slug: 'api/value' },
        { label: 'BigValue', slug: 'api/bigvalue' },
        { label: 'Types', slug: 'api/types' },
        { label: 'Signal', slug: 'api/signal' },
        { label: 'Connection', slug: 'api/connection' },
      ] },
      { label: 'Help', items: ['troubleshooting', 'diagnostics'] },
      { label: 'Playground', link: '/playground/', badge: { text: 'Try it' } },
    ],
  })],
});
