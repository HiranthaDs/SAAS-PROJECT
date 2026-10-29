# Hich Solutions Nexora Suite

An industry-aware, multi-tenant SaaS operating system for running sales, finance, inventory, people, branches, customer operations, hotels, medical centers, salons, pharmacies, workshops, retail businesses, and other specialized workflows from one secure workspace.

The application uses a browser-based JavaScript interface, Supabase Authentication, PostgreSQL, Row Level Security (RLS), Supabase Storage, Realtime subscriptions, and a portable server build suitable for local development or cloud deployment.

## Contents

- [Product overview](#product-overview)
- [Core design principles](#core-design-principles)
- [System architecture](#system-architecture)
- [Supported business profiles](#supported-business-profiles)
- [Authentication and workspace creation](#authentication-and-workspace-creation)
- [Organizations, branches, and access control](#organizations-branches-and-access-control)
- [Core ERP and operational modules](#core-erp-and-operational-modules)
- [Hotel operating system](#hotel-operating-system)
- [Medical center and patient queue](#medical-center-and-patient-queue)
- [Other industry modules](#other-industry-modules)
- [Database security and concurrency](#database-security-and-concurrency)
- [Public portals and routes](#public-portals-and-routes)
- [Project structure](#project-structure)
- [Local setup](#local-setup)
- [Database setup and migrations](#database-setup-and-migrations)
- [Running the application](#running-the-application)
- [Build and deployment](#build-and-deployment)
- [Verification and testing](#verification-and-testing)
- [Important database functions](#important-database-functions)
- [Operational guidance](#operational-guidance)
- [Troubleshooting](#troubleshooting)
- [External channel integrations](#external-channel-integrations)

## Product overview

Nexora Suite provides a single workspace in which business data is shared across only the modules that should share it. A user signs in to an organization, receives a role and an optional branch assignment, and then sees the operational modules enabled for that organization's business profile.

The platform includes:

- Multi-tenant organizations and isolated organization data.
- Multiple branches or operating locations.
- System administrator, workspace owner, administrator, manager, member, and viewer access levels.
- Fine-grained permissions for operational actions.
- Public customer and patient portals that do not require a SaaS account.
- Customer records, sales, invoices, inventory, suppliers, stock movements, employees, payroll, projects, finance, and reporting.
- Industry-specific workflows with isolated records and workflow stages.
- Real-time salon, hotel, and medical queue updates.
- Printable receipts, confirmations, service documents, hotel invoices, and patient queue tickets.
- Browser-responsive interfaces for desktop, tablet, mobile phones, reception screens, and doctor devices.

## Core design principles

### 1. Tenant isolation

Every business record belongs to an `org_id`. PostgreSQL RLS policies verify organization membership before returning or changing data. A normal user cannot access another organization's records by changing a URL, a JavaScript variable, or an API request.

### 2. Branch isolation

Location-enabled businesses use records in `salon_locations` as the common branch model. The historical table name is retained for migration compatibility, but locations are shared by hotels, clinics, automotive workshops, retail branches, salons, restaurants, and other location-enabled industries.

Branch-bound staff receive a row in `organization_user_access`. Access checks combine:

- Organization membership.
- Membership status.
- Organization role.
- Assigned branch.
- Fine-grained permission flags.

### 3. Database-enforced business rules

Critical rules are enforced in PostgreSQL functions and transactions. The user interface provides validation and clear messages, but it is not the security boundary.

Examples include:

- Hotel capacity is checked while the room type is locked.
- A medical call-next request locks the queue and the selected patient record.
- Sales confirmation creates inventory, invoice, and accounting records together.
- Cross-industry module records are rejected by a database trigger.
- Branch-assigned employees cannot read or change data from another branch.

### 4. Idempotent external operations

External hotel reservations use provider and external reservation identifiers. Retrying the same import returns the existing booking instead of consuming room capacity twice.

### 5. Public access with limited capabilities

Public portals use narrowly scoped `SECURITY DEFINER` functions. Anonymous visitors may check published availability, create a booking or queue ticket, and inspect a ticket using an unguessable token. They do not receive general table access.

## System architecture

```text
Browser / Mobile / Reception Screen
                 |
                 | Supabase JS client, HTTPS, Realtime
                 v
      Supabase Authentication
                 |
                 v
PostgreSQL + Row Level Security + RPC functions
     |                 |                 |
     |                 |                 +-- Activity and audit log
     |                 +-- Supabase Storage (hotel room images)
     +-- Realtime changes (bookings, queues, availability)

Portable application server
     +-- Serves the application shell, CSS, and bundled JavaScript
     +-- Provides protected account-administration endpoints
     +-- Uses the Supabase service key only on the server
```

### Frontend

- `dist/index.html` contains the public marketing, authentication, and application shells.
- `dist/assets/app.js` contains application state, renderers, public portals, forms, workflows, and Supabase calls.
- `dist/assets/styles.css`, `system-theme.css`, `schedule-reference.css`, and `hotel-medical.css` provide the responsive design system.
- `utils/supabase/client.js` creates the browser Supabase client using publishable credentials.

### Server build

`scripts/build.mjs` bundles the JavaScript with esbuild and creates `dist/server/index.js`. The generated server:

- Serves the application and compiled assets.
- Handles account creation.
- Allows authorized workspace super administrators to provision employee accounts.
- Validates Supabase access tokens server-side.
- Keeps the Supabase secret key out of browser code.

### Database

SQL migrations live in `supabase/migrations`. They are ordered from `001` through `021` and are designed to be safely re-applied by the setup script.

## Supported business profiles

The onboarding system can configure the following profiles:

| Business type | Primary operational focus |
| --- | --- |
| Retail & Grocery | Branch POS, receiving, stock, suppliers, loyalty, and finance |
| Pharmacy | Prescriptions, clinical verification, batches, expiry, POS, and audit history |
| Salon & Wellness | Service catalogue, public booking, availability, staff, reminders, checkout, and loyalty |
| Automotive Service | Vehicles, job cards, inspections, services, parts, suppliers, history, and reminders |
| General Business ERP | Sales, projects, finance, inventory, people, and services |
| Clothing & Fashion | Collections, styles, sampling, production, quality, variants, and sales |
| Restaurant & Cafe | Orders, tables/channels, kitchen preparation, service, POS, and ingredients |
| Hotel & Hospitality | Properties, rooms, booking inventory, arrivals, invoices, channels, and occupancy |
| Construction & Contracting | Sites, work packages, BOQs, contractors, inspections, and cost control |
| Real Estate & Property | Properties, inquiries, viewings, offers, leases, commissions, and maintenance |
| Education & Training | Enrollments, classes, attendance, assessment, fees, and faculty |
| Clinic & Healthcare | Medical centers, doctors, patient queues, consultation flow, billing, and stock |
| Logistics & Delivery | Shipments, routes, dispatch, vehicles, proof of delivery, and costing |
| Manufacturing & Production | Work orders, materials, work centers, production, quality, and finished goods |
| Agriculture & Farming | Fields, crop cycles, inputs, field logs, harvests, stock, and farm profitability |

`modules_for_business_type()` determines the enabled application modules. `industry_module_key()` maps each specialized profile to its isolated module key.

## Authentication and workspace creation

### New account flow

1. A user creates an account through `/api/signup`.
2. The server validates the email, password, and name.
3. Supabase creates and confirms the authentication user.
4. `handle_new_user()` creates:
   - A profile.
   - A new organization.
   - An owner membership.
   - Organization settings.
5. The first user becomes the workspace owner/super administrator.
6. Onboarding collects the company, industry, branch, employee, and industry-specific preferences.
7. `configure_business()` enables only the modules required by that business type.

### Employee account flow

Workspace owners create employee accounts through the protected admin API. The server:

1. Validates the requesting Supabase session.
2. Confirms the user is the workspace owner or an authorized system administrator.
3. Creates the Supabase authentication account.
4. Removes the temporary auto-created workspace for an employee account.
5. Adds the employee to the correct organization.
6. Assigns a branch, title, role, and permission map.
7. Creates or links the corresponding employee record.
8. Requires a private password change at first login.
9. Writes the action to `activity_log`.

### Login paths

- Normal workspace login: `/?login=admin`
- Branch employee login: `/staff/{employee_login_slug}`
- Public marketing page: `/`

The permanent branch URL does not replace authentication. It selects and validates the expected branch after sign-in.

## Organizations, branches, and access control

### Platform roles

| Role | Scope |
| --- | --- |
| `system_admin` | Cross-organization platform operations, billing state, suspension, and support notices |
| `super_admin` | Workspace-level super administrator |
| `user` | Standard authenticated platform user |

### Organization membership roles

| Membership role | Typical authority |
| --- | --- |
| `owner` | Full organization control and employee account provisioning |
| `admin` | Administrative and operational management |
| `manager` | Operational management based on permission flags |
| `member` | Assigned operational actions |
| `viewer` | Read-only access where permitted |

### Fine-grained permissions

The current permission map includes:

| Permission | Capability |
| --- | --- |
| `salon_view` | View branch/salon operations |
| `salon_create` | Create salon bookings |
| `salon_move` | Move salon workflow cards |
| `salon_approve` | Confirm salon bookings |
| `salon_allocate` | Assign responsible salon employees |
| `hotel_view` | View hotel properties, rooms, occupancy, and bookings |
| `hotel_bookings` | Create and advance hotel reservations |
| `hotel_manage` | Configure properties, room types, images, and channel connections |
| `medical_view` | View medical centers, sessions, tickets, and outcomes |
| `medical_issue` | Issue patient numbers |
| `medical_call` | Call, start, complete, or mark patient numbers as no-show |
| `medical_manage` | Configure centers, doctors, staff allocations, and sessions |
| `customers_view` | View customer/patient/guest records |
| `sales_view` | View sales, POS, receipts, and income |
| `settings_view` | View workspace settings |

Owners, system administrators, and applicable super administrators pass elevated checks. Other users are evaluated against the explicit JSON permission map.

### Branch access logic

`can_access_salon_location(org_id, location_id)` is the shared branch guard. It returns true only when the user is:

- A platform system administrator.
- The workspace super administrator/owner.
- An active organization member assigned to that location.

Hotel, medical, POS, salon, automotive, inventory, supplier, and employee queries use this branch boundary.

## Core ERP and operational modules

### Sales and order-to-cash

The order-to-cash engine connects sales, inventory, invoices, and accounting.

When a sales order is confirmed:

1. The order and its lines are locked and validated.
2. Default accounting accounts are created when missing.
3. Stock availability is checked for stockable products.
4. Delivery stock movements are posted.
5. The sales order becomes confirmed.
6. An invoice and invoice lines are created.
7. Balanced journal entries are posted.

`record_invoice_payment()` records payment and posts the corresponding accounting movement.

### Point of sale

The POS supports:

- Product and service lines.
- Salon appointments and automotive job-card checkout.
- Branch-aware products and stock.
- Cash, card, and other payment methods.
- Amount tendered and change.
- Loyalty redemption and rewards.
- Customer creation from checkout.
- Receipt printing.
- Automatic stock and financial posting.

### Inventory and suppliers

Inventory logic includes:

- Products, SKU, barcode, unit, cost, selling price, tax, and reorder level.
- Branch stock.
- Suppliers and supplier categories.
- Inventory receipts and receipt lines.
- Stock movements for receipt, delivery, transfer, and adjustment.
- Batch numbers and expiry dates.
- Reorder warnings and branch inventory reports.

`receive_inventory_stock()` validates the organization, branch, supplier, and item list before updating stock.

### Customers and loyalty

Customer records may include contact information, notes, birthday, loyalty balance, and transaction history. Loyalty credits and redemption are recorded as separate transactions so the current balance remains auditable.

### People and payroll

The people module provides:

- Employee master records.
- Branch assignment.
- Department, role, status, contact, identity, and emergency fields.
- Compensation configuration.
- Monthly or hourly pay types.
- Fixed additions and deductions.
- EPF/ETF rates.
- Paysheet preparation.
- Payroll workflow states.
- Employee directories, departments, positions, and performance views.

Payroll data is available only to elevated administrators. It is not exposed to standard operational users.

### Finance

Finance records include:

- Chart of accounts.
- Journal entries and balanced journal lines.
- Invoices and invoice items.
- Customer payments.
- Expenses.
- Receivables and overdue summaries.

### Projects and services

The platform supports projects, tasks, timesheets, service orders, assignments, due dates, progress, and budgets.

## Hotel operating system

The hotel module is a dedicated inventory and reservation engine, not a generic kanban record.

### Hotel data model

| Table | Purpose |
| --- | --- |
| `hotel_properties` | Hotel profile for a branch, public slug, address, contacts, check-in/out, currency, and amenities |
| `hotel_room_types` | Room category, physical quantity, occupancy limits, nightly rate, inclusions, and images |
| `hotel_bookings` | Guest reservation, stay dates, requested rooms, status, source, totals, payment, and invoice number |
| `hotel_channel_connections` | Agoda/Booking.com/Tripadvisor/Expedia/custom API metadata and synchronization state |

### Room inventory model

`room_count` is the number of physical rooms available for a room type. If a room type has five rooms, no more than five active room units can overlap on any stay date.

Active capacity includes bookings in these states:

- `pending`
- `confirmed`
- `checked_in`
- `checked_out` when the stored stay range overlaps the request

Bookings in `cancelled` or `no_show` do not consume future capacity.

Stay ranges use half-open date logic:

```text
[arrival_date, departure_date)
```

The departure day is not counted as an occupied night, allowing another guest to arrive on the same date after checkout.

### Atomic overbooking protection

All direct and public reservations eventually use `hotel_booking_payload()` internally.

The transaction:

1. Loads the active property.
2. Locks the requested room-type row with `FOR UPDATE`.
3. Validates arrival and departure.
4. Validates room, adult, and child quantities.
5. Sums all overlapping active room units.
6. Rejects the booking when `reserved + requested > room_count`.
7. Calculates nights, subtotal, total, booking number, and invoice number.
8. Inserts the reservation.

The database lock serializes simultaneous booking attempts for the same room type. Two guests cannot both consume the last room.

### Hotel booking statuses

```text
pending -> confirmed -> checked_in -> checked_out
                  \-> cancelled
                  \-> no_show
```

Status changes use `update_hotel_booking_status()` and require hotel booking permission plus branch access.

### Public hotel booking flow

Public URL:

```text
/hotel/{public_slug}
```

The guest can:

1. Select arrival and departure dates.
2. Select the number of rooms.
3. View live remaining capacity by room type.
4. Review room images, description, inclusions, occupancy limits, and nightly rate.
5. Select a room type.
6. Enter name, WhatsApp number, optional email, adults, children, and arrival details.
7. Submit the reservation.
8. Receive the booking number, total, dates, and status.
9. Print the confirmation.

Public booking does not expose hotel tables. It uses `get_public_hotel()` and `create_public_hotel_booking()`.

### Room images

- Images are stored in the `hotel-room-images` Supabase Storage bucket.
- Each room type can contain up to five images.
- Each file is limited to 5 MB.
- JPEG, PNG, WebP, and GIF are accepted.
- Reads are public because the images appear on anonymous booking pages.
- Upload/update/delete policies validate the organization ID in the storage path.

### Availability calendar and reporting

The hotel dashboard includes a 14-day matrix:

- X-axis: calendar date.
- Y-axis: room type.
- Each cell: booked room units and remaining physical rooms.

The summary includes:

- Fourteen-day occupancy percentage.
- Used versus available room nights.
- Active booking value.
- Arrivals today.
- Booking status.
- Paid amount and outstanding balance.
- Direct versus external source.

### Hotel invoices

Every booking receives an invoice number. The printable hotel invoice includes:

- Hotel name and contact details.
- Guest details.
- Booking and invoice numbers.
- Room type.
- Arrival and departure.
- Nights and room quantity.
- Adults and children.
- Nightly rate, subtotal, tax, total, paid amount, and balance.

### External booking channels

The channel configuration screen provides records for:

- Agoda.
- Booking.com.
- Tripadvisor.
- Expedia.
- Custom APIs.

Configuration stores only provider metadata and a credential/vault reference. Raw API secrets should be stored in a protected server secret manager, never in browser code or database fields intended for display.

`upsert_hotel_channel_booking()` imports an external reservation into the same `hotel_bookings` table used by direct reservations. It applies the same room lock and capacity check.

The idempotency key is:

```text
(property_id, provider/source, external_reservation_id)
```

Repeating the same import returns the existing reservation instead of creating a duplicate.

## Medical center and patient queue

The medical module supports a center with multiple doctors, shared or doctor-specific staff, public patient numbers, doctor call-next controls, live status, and outcome reporting.

### Medical data model

| Table | Purpose |
| --- | --- |
| `medical_centers` | Branch center profile, public slug, contact details, timezone, and default slot duration |
| `medical_doctors` | Doctor, specialty, room, employee link, and queue prefix |
| `medical_staff_assignments` | Assign an employee to the center, one doctor, or a supervisory role |
| `medical_sessions` | Doctor, date, start/end time, minutes per patient, capacity, and session status |
| `medical_queue_tickets` | Patient number, doctor session, source, priority, state, timestamps, and public token |

### Doctor and staff allocation

A doctor may be linked to an employee login. Staff assignments can apply to:

- A specific doctor.
- The whole medical center.
- A queue staff role.
- A doctor role.
- A supervisor role.

The user must still have the corresponding medical permission. An assignment does not bypass organization membership, branch access, or RLS.

### Session capacity

The database derives capacity from the session time range and the minutes allocated per patient:

```text
capacity = floor((end time - start time) / slot minutes)
```

Example:

```text
09:00 to 12:00 = 180 minutes
15 minutes per patient
capacity = 12 patients
```

The trigger `calculate_medical_session_capacity` recalculates this value on insert or when the time/slot duration changes. The browser cannot submit an artificially larger capacity.

### Session statuses

- `planned`
- `open`
- `paused`
- `closed`
- `cancelled`

Only active sessions for the center's local date may issue new patient numbers.

### Patient number sources

- `qr`
- `link`
- `staff`
- `walk_in`

Source reporting helps the center understand how patients arrived.

### Public patient flow

Public URL:

```text
/medical/{public_slug}
```

Patients may:

1. Scan the generated QR code or open the link.
2. See today's active doctors, specialties, rooms, session times, issued numbers, waiting count, and current number.
3. Select a specific doctor or choose first available.
4. Enter their name and optional WhatsApp number.
5. Receive a prefixed number such as `A-001`.
6. Keep the page open for automatic status updates.
7. Print the number when needed.

### Smart first-available doctor selection

If the patient does not select a doctor, `issue_medical_queue_number()`:

1. Finds today's planned/open sessions.
2. Counts active waiting/called/in-consultation tickets in each session.
3. Sorts by the shortest active queue.
4. Uses session start time as the tie-breaker.
5. Locks the selected session.
6. Rechecks session capacity.
7. Issues the next unique number for that doctor session.

This logic distributes patients across two or more doctors without mixing their number sequences.

### Atomic call-next logic

`call_next_medical_queue()` prevents two doctors or staff members from calling the same patient:

1. The doctor session is locked.
2. The first waiting ticket is selected by priority and queue number.
3. `FOR UPDATE SKIP LOCKED` prevents another concurrent caller from selecting that ticket.
4. The ticket changes to `called` and stores `called_at`.
5. The action is written to the audit log.

### Patient ticket states

```text
waiting -> called -> in_consultation -> completed
       \-> no_show
       \-> cancelled
```

The dashboard exposes controlled actions for call, consultation start, completion, and no-show.

### Public ticket privacy

Public status lookup uses a random UUID token. It returns only the queue number, status, doctor, specialty, room, timestamps, and number of people ahead. It does not expose general patient records or other tickets.

### Medical reporting

The live dashboard shows:

- Waiting patients.
- Called/in-consultation patients.
- Completed patients.
- No-show count and rate.
- Numbers issued per doctor session.
- Session capacity.
- Minutes per patient.
- QR/link/staff/walk-in source totals.
- Daily ticket history and timestamps.

## Other industry modules

### Salon and wellness

- Service catalogue.
- Branch-specific employee capacity.
- Public booking link.
- Date and time availability.
- Staff unavailability.
- Booking workflow/kanban.
- WhatsApp reminder status.
- Appointment checkout and loyalty.
- Realtime booking updates.

### Pharmacy

- Prescription queue.
- Clinical verification stages.
- Medicine batches and expiry.
- Dispensing and POS.
- Auditable status advancement.

### Automotive

- Customer and vehicle profiles.
- Branch job cards.
- Check-in, inspection, approval, repair, quality, ready, and delivery stages.
- Parts, labor, services, suppliers, and stock receiving.
- Complete vehicle service history.
- Next-service date and mileage reminders.

### Isolated industry records

Fashion, restaurant, construction, real estate, education, logistics, manufacturing, and agriculture use `module_records` with a dedicated `module_key` and profile-specific statuses.

`enforce_industry_module_isolation()` rejects records whose module key does not match the organization's business type.

`advance_industry_record()` selects the valid next state from the configured workflow and writes the action to the audit log.

## Database security and concurrency

### Row Level Security

RLS is enabled on organization-owned tables. Policies use helpers including:

- `is_platform_admin()`
- `is_system_admin()`
- `is_org_member()`
- `is_org_super_admin()`
- `can_manage_org()`
- `has_org_permission()`
- `can_access_salon_location()`
- `can_operate_medical_center()`

### Service key boundary

`SUPABASE_SECRET_KEY` is used only by server scripts and protected account APIs. It must never be added to frontend JavaScript, committed environment files, screenshots, or documentation containing real values.

### Audit log

Important actions are written to `activity_log`, including:

- Account creation and permission changes.
- First-login password changes.
- Business configuration.
- Location creation and updates.
- Hotel booking creation and channel import.
- Industry workflow changes.
- Medical call-next actions.
- System notifications and workspace state changes.

### Concurrency controls

| Operation | Protection |
| --- | --- |
| Hotel room reservation | Room-type row lock plus overlapping date-range capacity sum |
| External booking import | Same capacity lock plus idempotent provider/external ID key |
| Medical ticket issue | Session lock, capacity recount, and unique session/number key |
| Medical call next | Session lock and ticket `FOR UPDATE SKIP LOCKED` |
| POS checkout | Transactional stock, customer, loyalty, payment, and receipt operations |
| Sales confirmation | Transactional order, stock movement, invoice, and journal posting |

## Public portals and routes

| Route | Purpose | Authentication |
| --- | --- | --- |
| `/` | Product/marketing page | Public |
| `/?login=admin` | Main workspace login | Public entry, authenticated workspace |
| `/book/{salon_slug}` | Salon service and live availability booking | Public |
| `/hotel/{hotel_slug}` | Hotel live room availability and reservation | Public |
| `/medical/{center_slug}` | Patient queue number and live ticket status | Public |
| `/staff/{branch_slug}` | Permanent employee branch login | Authentication required |

The development server returns the application shell for these client routes.

## Project structure

```text
nexora-suite/
├── .openai/
│   └── hosting.json                 # Existing Sites project identity
├── dist/
│   ├── index.html                   # Application, auth, and public shells
│   ├── assets/
│   │   ├── app.js                   # Main source application
│   │   ├── app.bundle.js            # Generated browser bundle
│   │   ├── styles.css               # Main styles
│   │   ├── system-theme.css         # Product theme
│   │   ├── schedule-reference.css   # Schedule/calendar styles
│   │   └── hotel-medical.css        # Hotel/medical portals and dashboards
│   └── server/
│       └── index.js                 # Generated portable server
├── scripts/
│   ├── build.mjs
│   ├── dev-server.mjs
│   ├── setup-supabase.mjs
│   └── verify-*.mjs                 # Integration and browser verification
├── supabase/
│   └── migrations/
│       └── 001...021_*.sql
├── utils/
│   └── supabase/client.js
├── .env.example
├── package.json
└── README.md
```

## Local setup

### Requirements

- Node.js 20 or later. Node.js 22 is recommended.
- npm.
- A Supabase project.
- A PostgreSQL connection string for the same Supabase project.
- Google Chrome for browser verification scripts.

### Install dependencies

```bash
npm install
```

### Environment configuration

Copy `.env.example` to `.env.local` and add real values:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your_publishable_key

SUPABASE_URL=https://your-project.supabase.co
SUPABASE_PUBLISHABLE_KEY=your_publishable_key
SUPABASE_SECRET_KEY=your_server_secret_key
DATABASE_URL=postgresql://user:password@host:5432/postgres

SUPER_ADMIN_EMAIL=admin@example.com
SUPER_ADMIN_PASSWORD=replace-with-a-strong-password
```

Optional verification settings:

```dotenv
APP_URL=http://127.0.0.1:3000
CHROME_PATH=C:\Program Files\Google\Chrome\Application\chrome.exe
```

Never commit `.env.local`. The repository ignores `.env` and `.env.*` files except `.env.example`.

## Database setup and migrations

Apply every SQL migration and provision/update the configured administrator:

```bash
npm run setup:supabase
```

The setup script:

1. Loads `.env.local`.
2. Connects to PostgreSQL.
3. Uses Supabase transaction pooling on port `6543` when the provided connection is a Supabase pooler URL using session port `5432`.
4. Applies migrations in filename order.
5. Creates or updates the configured administrator.
6. Ensures the administrator owns an organization and has the expected platform role.

### Migration summary

| Migration | Main responsibility |
| --- | --- |
| `001` | Initial organizations, memberships, ERP tables, RLS, and new-user provisioning |
| `002` | Extended purchasing, manufacturing, HR, POS, documents, fleet, and automation tables |
| `003`–`004` | Instant signup and generic industry application records |
| `005` | Order-to-cash, invoice, inventory, and journal posting engine |
| `006` | Retail customers, POS, loyalty, compensation, and payroll |
| `007`–`008` | Universal industry profiles and onboarding |
| `009`–`012` | Salon booking, catalogue, staff capacity, and public availability |
| `013`–`014` | Salon workflow permissions, branches, and employee portals |
| `015`–`016` | System-admin hierarchy, billing gate, and role compatibility |
| `017` | Automotive branches, services, suppliers, and service history |
| `018` | System notifications and read tracking |
| `019` | Employee/payroll detail and branch inventory receiving |
| `020` | Ten isolated industry workflows and module-key enforcement |
| `021` | Hotel inventory/booking/channel engine and medical multi-doctor queue |

Do not delete or rewrite an applied production migration. Add a new numbered migration for future schema changes.

## Running the application

Start the development server:

```bash
npm run dev
```

Default URL:

```text
http://localhost:3000
```

The development server serves files from `dist`, provides the protected account APIs, and falls back to `index.html` for public portal routes.

## Build and deployment

Create the production browser bundle and portable server:

```bash
npm run build
```

Build behavior:

- Reads public Supabase values from `.env.local`.
- Bundles `dist/assets/app.js` into `app.bundle.js`.
- Combines product CSS.
- Generates `dist/server/index.js`.
- Keeps server-only Supabase credentials as deployment environment values.

For production, configure these server environment values securely:

- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY`

Do not replace the publishable browser key with the secret key.

## Verification and testing

### Syntax and bundle checks

```bash
npm run check
npm run build
```

### Core verification scripts

| Command | Coverage |
| --- | --- |
| `npm run verify:supabase` | Authentication, provisioning, base tenant isolation, and core records |
| `npm run verify:order-to-cash` | Sales confirmation, inventory, invoice, payment, and accounting |
| `npm run verify:retail-erp` | Retail POS, loyalty, stock, and payroll |
| `npm run verify:industries` | Business profile configuration |
| `npm run verify:industry-expansion` | Expanded industry interface behavior |
| `npm run verify:industry-db` | Module mapping, default locations, cross-industry isolation, and advancement |
| `npm run verify:salon` | Salon booking, availability, reminders, and checkout |
| `npm run verify:salon-locations` | Multi-location salon and employee portal rules |
| `npm run verify:admin-hierarchy` | System/workspace admin boundaries, suspension, and branch restriction |
| `npm run verify:login-paths` | Main login, permanent branch login, password change, and isolation |
| `npm run verify:notifications` | System notification delivery and read state |
| `npm run verify:people-retail` | Employee data, payroll, and retail receiving |
| `npm run verify:hotel-medical` | Hotel capacity, channel idempotency, medical balancing, capacity, call-next, and storage |
| `npm run verify:hotel-medical-browser` | Desktop/mobile hotel and medical portals, admin dashboards, QR, and browser errors |
| `npm run verify:browser-login` | Full public/auth/employee/admin browser flow and responsive product checks |

### Hotel and medical integration assertions

`verify:hotel-medical` creates temporary isolated tenants and proves that:

- A five-room type accepts five overlapping room units.
- A sixth overlapping room is rejected.
- Live availability reaches zero.
- Retrying a channel reservation with the same external ID is idempotent.
- Two doctor sessions balance first-available patients.
- Capacity is calculated from time and slot duration.
- A full session rejects another number.
- Call-next selects exactly one waiting patient.
- Public ticket status works with the private token.
- The hotel image storage bucket exists.
- Temporary test organizations are removed in `finally` cleanup.

### Browser QA artifacts

Browser scripts place screenshots in `.chrome-qa/`. These are local QA artifacts and should not be treated as runtime data.

## Important database functions

### Organization and access

- `modules_for_business_type(target_type)`
- `industry_module_key(target_type)`
- `business_type_uses_locations(target_type)`
- `configure_business(...)`
- `get_my_workspace_gate()`
- `get_system_admin_console()`
- `set_organization_access_state(...)`
- `has_org_permission(org_id, permission)`
- `can_access_salon_location(org_id, location_id)`

### Hotel

- `get_public_hotel(slug, arrival, departure, rooms)`
- `create_public_hotel_booking(...)`
- `create_hotel_booking(...)`
- `upsert_hotel_channel_booking(...)`
- `update_hotel_booking_status(...)`

`hotel_booking_payload()` is an internal helper. Direct execution is revoked from public, anonymous, and authenticated application roles.

### Medical

- `get_public_medical_center(slug)`
- `issue_medical_queue_number(...)`
- `call_next_medical_queue(session_id)`
- `advance_medical_queue(ticket_id, status)`
- `get_medical_ticket_status(token)`
- `can_operate_medical_center(center_id, permission)`

### Sales, POS, and payroll

- `confirm_sales_order(order_id)`
- `record_invoice_payment(invoice_id, amount)`
- `checkout_pos(...)`
- `prepare_payroll_run(org_id, month)`
- `advance_payroll_run(run_id, action)`
- `save_employee_paysheet(...)`
- `receive_inventory_stock(...)`

## Operational guidance

### Creating a hotel branch

1. Configure the organization as `hotel`.
2. Create or select the branch.
3. Open **Front Desk & Rooms**.
4. Add hotel details.
5. Add room types with their real physical quantities.
6. Add price, occupancy limits, inclusions, description, and up to five images.
7. Copy the public booking link.
8. Configure channel connections.
9. Ensure every external reservation is imported through the channel booking RPC.

Never increase room quantity merely to accept a booking. Quantity must match physical sellable inventory.

### Operating a medical queue

1. Configure the organization as `healthcare_clinic`.
2. Add the medical center for the branch.
3. Add doctors and optional employee links.
4. Allocate queue staff to the center or a doctor.
5. Create a doctor session with date, start/end, and minutes per patient.
6. Open the session.
7. Print or share the QR code.
8. Staff may issue walk-in numbers.
9. Doctors or authorized staff use **Call next**.
10. Mark called patients as in consultation, completed, or no-show.

### Suspending a workspace

System administrators can suspend an organization for billing or administrative reasons. Suspension blocks authenticated workspace access and public booking links until reactivation.

## Troubleshooting

### `Could not find the table ... in the schema cache`

The migration has not been applied to the Supabase project used by the application, or the database and API environment values point to different projects.

Run:

```bash
npm run setup:supabase
```

Then verify that the project reference in `SUPABASE_URL` matches the project encoded in `DATABASE_URL`.

### PostgreSQL connection reset or timeout on port 5432

The setup script automatically changes Supabase pooler URLs from session port `5432` to transaction port `6543`. Direct PostgreSQL URLs are left unchanged.

### Public booking link unavailable

Confirm that:

- The organization is active.
- The organization business type matches the portal.
- The property/center/salon is active.
- The slug is correct.
- Database migrations are current.

### A hotel room appears unavailable

Check all overlapping bookings, including external/channel sources. Pending and confirmed reservations consume inventory. Cancelled and no-show reservations do not.

### No medical sessions appear publicly

Confirm that:

- The session date matches the center's timezone.
- The session is `planned` or `open`.
- The doctor is active.
- The session has remaining calculated capacity.

### Employee cannot open a branch portal

Verify:

- Active membership.
- Correct organization.
- Correct branch in `organization_user_access`.
- Correct permanent employee portal slug.
- Required permission flags.

### Browser verification cannot start Chrome

Set `CHROME_PATH` in `.env.local` to the installed Chrome executable.

## External channel integrations

The repository includes the database and interface contract for external hotel channels, but live synchronization requires provider-specific access supplied by the hotel or integration partner.

For each provider, implement a protected server-side adapter that:

1. Loads the API secret from a secret manager.
2. Reads the provider property/room mapping.
3. Receives or polls reservations.
4. Normalizes dates, guest counts, room quantity, and external ID.
5. Calls `upsert_hotel_channel_booking()`.
6. Records synchronization time and status.
7. Updates cancellations through the controlled booking status function.
8. Retries safely using the same external reservation ID.

Never call provider APIs directly from browser JavaScript because credentials would be exposed.

## Security checklist

- Keep `.env.local` out of Git.
- Never place `SUPABASE_SECRET_KEY` in browser code.
- Use generated public slugs and ticket tokens.
- Preserve RLS on every organization-owned table.
- Use RPC functions for capacity-sensitive operations.
- Do not bypass the hotel booking function with direct inserts.
- Do not manually edit medical session capacity.
- Store external API credentials in a protected secret manager.
- Review `activity_log` for privileged changes.
- Apply schema changes using new numbered migrations.

## Repository

GitHub: <https://github.com/HiranthaDs/SAAS-PROJECT>

---

Hich Solutions Nexora Suite is designed as a connected business operating system: one authenticated workspace, strict tenant and branch boundaries, industry-specific workflows, and database-enforced protection for critical operations.
