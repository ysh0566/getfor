---
name: Fortress Identity Hub
colors:
  surface: '#051424'
  surface-dim: '#051424'
  surface-bright: '#2c3a4c'
  surface-container-lowest: '#010f1f'
  surface-container-low: '#0d1c2d'
  surface-container: '#122131'
  surface-container-high: '#1c2b3c'
  surface-container-highest: '#273647'
  on-surface: '#d4e4fa'
  on-surface-variant: '#c6c6cd'
  inverse-surface: '#d4e4fa'
  inverse-on-surface: '#233143'
  outline: '#909097'
  outline-variant: '#45464d'
  surface-tint: '#bec6e0'
  primary: '#bec6e0'
  on-primary: '#283044'
  primary-container: '#0f172a'
  on-primary-container: '#798098'
  inverse-primary: '#565e74'
  secondary: '#c0c1ff'
  on-secondary: '#1000a9'
  secondary-container: '#3131c0'
  on-secondary-container: '#b0b2ff'
  tertiary: '#4edea3'
  on-tertiary: '#003824'
  tertiary-container: '#001c10'
  on-tertiary-container: '#009365'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#dae2fd'
  primary-fixed-dim: '#bec6e0'
  on-primary-fixed: '#131b2e'
  on-primary-fixed-variant: '#3f465c'
  secondary-fixed: '#e1e0ff'
  secondary-fixed-dim: '#c0c1ff'
  on-secondary-fixed: '#07006c'
  on-secondary-fixed-variant: '#2f2ebe'
  tertiary-fixed: '#6ffbbe'
  tertiary-fixed-dim: '#4edea3'
  on-tertiary-fixed: '#002113'
  on-tertiary-fixed-variant: '#005236'
  background: '#051424'
  on-background: '#d4e4fa'
  surface-variant: '#273647'
typography:
  headline-xl:
    fontFamily: Inter
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  title-md:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  unit: 8px
  container-max: 1280px
  gutter: 24px
  margin-mobile: 16px
  margin-desktop: 40px
  stack-sm: 8px
  stack-md: 16px
  stack-lg: 32px
---

## Brand & Style

The design system is anchored in the concept of "Invisible Security"—a philosophy that balances ironclad protection with frictionless user experience. The brand personality is authoritative, calm, and technologically advanced. It aims to evoke a sense of absolute safety without the intimidating "locked down" feeling of legacy security software.

The visual style is a hybrid of **Corporate Modern** and **Glassmorphism**. By using translucent layers and background blurs, the interface feels lightweight and futuristic, while the underlying deep blue palette maintains a professional, high-trust foundation. The UI should prioritize clarity and "breathing room," ensuring that critical security information is never obscured by visual clutter.

## Colors

This design system utilizes a "Deep Dark" mode as the default state to reinforce the feeling of a secure vault.

- **Primary (Midnight Blue):** Used for the base canvas and primary surfaces to establish a grounded, institutional feel.
- **Accent (Electric Indigo):** Used for primary actions, progress indicators, and tech-forward highlights.
- **Functional Colors:** Emerald, Amber, and Rose are used strictly for status communication (Safe, Warning, and Critical).
- **Glass Layers:** Surfaces are created using semi-transparent variations of the primary color with `backdrop-filter: blur()`, allowing background accents to bleed through subtly.

## Typography

The design system relies on **Inter** for its systematic, utilitarian, and highly legible characteristics.

- **Headlines:** Use tight letter-spacing and bold weights to convey strength and urgency.
- **Body Text:** Maintained at a comfortable 16px to ensure readability during critical security audits.
- **Labels:** Small labels use an uppercase transform and increased letter spacing to create clear metadata hierarchy without overwhelming the primary content.

## Layout & Spacing

The design system employs a **Fluid Grid** model based on an 8px square rhythm.

- **Desktop:** A 12-column grid with 24px gutters. Content is housed in "Glass Modules" that can span multiple columns.
- **Mobile:** A 4-column grid with 16px margins.
- **Rhythm:** Vertical spacing between cards and sections should follow the `stack-lg` (32px) unit to maintain the "Invisible Security" aesthetic—avoiding dense clusters of information to reduce user anxiety.

## Elevation & Depth

Depth is achieved through **Glassmorphism** and refined outlines rather than traditional heavy shadows.

- **Surface Tiers:**
  - **Tier 0 (Background):** Solid Midnight Blue (#0F172A).
  - **Tier 1 (Cards/Modules):** Midnight Blue at 60% opacity with a 20px background blur and a 1px border (#FFFFFF 10% opacity).
  - **Tier 2 (Modals/Popovers):** Midnight Blue at 80% opacity, 40px background blur, and a subtle indigo-tinted shadow.
- **Outlines:** High-contrast "Ghost Borders" are used to define interactive areas, ensuring the UI remains accessible and structured even with transparent backgrounds.

## Shapes

The shape language uses **Rounded** (0.5rem) corners to soften the "industrial" feel of security software, making it more approachable.

- **Standard Elements:** Inputs and buttons use the 0.5rem (8px) base.
- **Large Containers:** Dashboard cards use `rounded-lg` (16px) to create a clear containerized feel.
- **Biometric Indicators:** Circular shapes are reserved strictly for biometric status icons (FaceID circles, Fingerprint scanners) to distinguish human-centric data from system-centric data.

## Components

- **Buttons:** Primary buttons use a solid Electric Indigo fill with white text. Secondary buttons are "Glass Ghost" buttons (semi-transparent with a 1px border). Success actions use Emerald Green sparingly.
- **Status Chips:** Small, pill-shaped indicators with a 10% opacity fill of their functional color (e.g., Emerald for "Active") and a 100% opacity dot icon.
- **Input Fields:** Darker than the surface background to create an "inset" feel. Borders glow Electric Indigo upon focus.
- **Identity Cards:** High-contrast cards that display Biometric Icons (FaceID, Passkey) as a central focal point. These use the Tier 1 Glassmorphism style.
- **Audit Lists:** Monospaced timestamps (using Inter's tabular numerals) combined with clear, high-contrast labels for event types.
- **Activity Gauges:** Circular progress indicators used for security scores, utilizing the success-to-error color spectrum.
