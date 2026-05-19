import './globals.css';

const basePath = process.env.NEXT_PUBLIC_BASE_PATH || '';

export const metadata = {
  title: 'Overture Explorer',
  description: 'Explore Overture Maps Foundation geospatial data',
  icons: {
    icon: `${basePath}/favicon.png`,
  },
};

const notoSans = `${basePath}/fonts/Noto Sans.woff2`;
const notoSansItalic = `${basePath}/fonts/Noto Sans Italic.woff2`;
const ptMono = `${basePath}/fonts/PT Mono.woff2`;

const fontFaceCSS = `
  @font-face { font-family: 'Noto Sans Bold'; font-weight: 700; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Bold Italic'; font-weight: 700; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Italic'; font-weight: 400; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Light'; font-weight: 300; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Light Italic'; font-weight: 300; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Medium'; font-weight: 500; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Medium Italic'; font-weight: 500; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans Regular'; font-weight: 400; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Bold'; font-weight: 700; font-width: 87.5%; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Bold Italic'; font-weight: 700; font-width: 87.5%; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Italic'; font-weight: 400; font-width: 87.5%; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Light'; font-weight: 300; font-width: 87.5%; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Light Italic'; font-weight: 300; font-width: 87.5%; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Medium'; font-weight: 500; font-width: 87.5%; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Medium Italic'; font-weight: 500; font-width: 87.5%; src: url('${notoSansItalic}') format('woff2'); }
  @font-face { font-family: 'Noto Sans SemiCondensed Regular'; font-weight: 400; font-width: 87.5%; src: url('${notoSans}') format('woff2'); }
  @font-face { font-family: 'PT Mono Regular'; font-weight: 400; src: url('${ptMono}') format('woff2'); }
`;

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <style dangerouslySetInnerHTML={{ __html: fontFaceCSS }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
