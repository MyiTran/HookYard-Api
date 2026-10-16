# AGENTS.md — HookYard Rails Backend

Working rules for AI agents (and humans) in this repository. They are based on the **actual** conventions in this codebase, not on generic Rails advice.

Context: this is a Golden Owl Rails API **boilerplate** (`README.md`) currently customized for HookYard. It is **early-stage**: only `User` / `Role` / `AllowlistedJwt` + Active Storage exist, and several directories are empty scaffolding (`app/queries`, `app/decorators`, `app/overrides`, `app/models/concerns`). Treat most of the repo as a template until proven otherwise.

## 1. Inspect before coding

- Always read the current related code before changing anything.
- **Never assume** a model, route, policy, operation, query, serializer, or job exists — verify it. Some examples in the base classes (`app/operations/application_operation.rb`, `app/queries/application_query.rb`) reference things that do not exist (e.g. `Product`).
- This repo is boilerplate: confirm real implementations before extending them.

## 2. Reuse existing backend architecture

- This is a **Rails API-only** app (`config/application.rb:40`). No views/assets/helpers.
- **Controllers stay thin** — strong params only, then render or delegate.
- Business logic → **Operations** extending `ApplicationOperation` (`app/operations/`). Class method `call` delegates to instance `call`.
- Filtering/sorting → **Query objects** extending `ApplicationQuery` (`app/queries/`), using its `filter`/`sort` helpers.
- Authorization → **Pundit policies** (`app/policies/`). Base `ApplicationPolicy` denies by default.
- Serialization → **Blueprinter** (`app/serializers/`), JSON via Oj.
- API errors → the existing `APIError::*` hierarchy (`app/errors/api_error/`) surfaced through `ExceptionFilter` (`app/controllers/concerns/exception_filter.rb`).
- **Do not introduce a new architecture pattern** (services/interactors/forms/decorators) unless explicitly asked.

## 3. Clean Code and Architecture Consistency

**Readable code**

- Prefer clear, descriptive names over short or clever ones.
- Keep methods focused on one responsibility; avoid deep nesting and prefer early returns when they read better.
- No magic values — use constants/enums/config (`config/initializers/constants.rb`, model enums such as `Role`).
- Do not add comments to explain confusing code — simplify the code instead. See **No unnecessary code comments** below for what is allowed.

**No unnecessary code comments**

- Do NOT add comments to normal application code.
- Prefer self-explanatory names, small methods, and clear structure instead of comments.
- Do not add comments that merely restate what the code does, e.g. `# get user`, `# check admin`, `# create project`, `// fetch data`, `// handle error`.
- If code requires a comment to be understandable, refactor the code first.
- Comments are allowed ONLY for:
  - non-obvious business constraints;
  - security-critical rationale;
  - framework/workaround behavior that cannot be made obvious in code;
  - temporary compatibility behavior that would otherwise be dangerous to remove.
- Even in those cases, explain WHY, not WHAT.
- Do not add TODO/FIXME comments unless explicitly requested.
- Do not add generated explanatory comments to specs. Specs should explain behavior through `describe` / `context` / `it` names instead.

**Do not duplicate logic**

- Search for an existing implementation before writing new logic.
- Reuse existing helpers, Operations, Queries, policies, serializers, concerns, or model methods.
- If the same business rule appears in multiple places, move it to the correct shared layer.
- Do not extract prematurely — extract only when duplication or a clear responsibility justifies it.

**Respect layer responsibilities**

- Controller: request parsing, authorization entry point, delegation, rendering.
- Policy: authorization and access scope.
- Operation: business workflow / use-case logic.
- Query: filtering / sorting / data retrieval.
- Model: persistence rules, associations, validations, small domain invariants.
- Serializer: output shape only.
- Job: background orchestration; delegate complex business logic to Operations.
- Spec: proves observable behavior and business rules, not implementation details.

Do not move logic between layers just because it is convenient.

**Follow existing folder/namespace structure**

- Put new code in the same directory/namespace pattern as similar existing code.
- Do **not** create `services/`, `helpers/`, `utils/`, `managers/`, etc. unless the repo already uses them or explicit approval is given.
- Reuse the sibling Operation / Query / Policy / Serializer class as the template — inspect similar classes first.

**Code and specs must tell the same story**

For every business rule: locate where it lives in production code, then write the focused spec at the correct level. Describe the expected business behavior; do not re-implement production logic inside the spec; assert inputs/outputs/state changes rather than private methods.

Example — rule: "A public signup always creates a `support` user and cannot self-assign admin."

- production: `RegistrationsController#create` assigns `support`; strong params drop any `role` input.
- specs: signup returns `role: "support"`; the DB user has the `support` role; sending `role: "admin"` does not grant admin.

The spec proves the rule; it does not reimplement the controller.

**Prefer behavior-driven tests**

- Request specs → API contract, status, auth, serialization.
- Policy specs → access rules.
- Operation specs → business workflows.
- Model specs → validations / associations / domain invariants.
- Job specs → enqueue / retry / delegation behavior.
- Avoid testing Rails/framework internals.

**Avoid over-engineering**

- Do not add design patterns just because they are "clean"; do not add a base class/concern/helper for a single trivial use.
- Prefer the simplest design that fits the existing architecture; refactor only for real duplication, complexity, or responsibility leakage.

**Consistency across a feature**

When implementing a feature, inspect all related layers: model, migration/schema, policy, operation, query, serializer, controller, routes, job, and specs. Do not implement one layer in isolation if the feature requires the others.

**Data and concurrency correctness**

- Do not rely only on Ruby validations for uniqueness/idempotency — back critical invariants with DB constraints.
- Think about concurrent requests, retries, duplicate jobs, and race conditions (especially webhook/event flows).
- Include concurrency/idempotency spec cases when a business rule depends on them.

**Self-review before reporting**

Check: Is any logic duplicated? Is any method/class doing too much? Is code in the correct layer? Are names understandable? Did I introduce unnecessary abstractions? Did I add any comment that can be removed by improving naming or structure? Are all remaining comments explaining WHY rather than WHAT? Do specs describe real business behavior and cover the important failure/security paths? Is the API contract still consistent? Is tenant isolation preserved? Is there dead/unused code from the change?

## 4. File, Class, and Folder Conventions

Use the CURRENT Rails architecture only. Before creating any class, inspect a similar existing one and match its namespace, constructor, `.call`/`#call`, error handling, serialization, naming, and spec style.

**Operations** (`app/operations/`) — one action per class, named for the action, extending `ApplicationOperation`:

- `app/operations/projects/create.rb` → `Projects::Create`
- `app/operations/projects/update.rb` → `Projects::Update`
- `app/operations/projects/invite_collaborator.rb` → `Projects::InviteCollaborator`
- `app/operations/endpoints/rotate_secret.rb` → `Endpoints::RotateSecret`

Do NOT introduce `app/services/` or classes like `ProjectService`, `ProjectsService`, `ProjectManager`, `WebhookHandler` unless the architecture is explicitly changed first. Inspect an existing Operation (e.g. `app/operations/blobs/create.rb`) before creating a new one.

**initialize and call conventions**

- Do NOT add `initialize` mechanically — use it only when the object needs inputs/dependencies/state for `#call`.
- Prefer descriptive keyword arguments when there are multiple inputs.
- `initialize` prepares input/dependencies ONLY; no business actions inside it. `call` performs the business operation.
- Do not create unnecessary instance variables; match the existing `ApplicationOperation.call` convention before deciding the exact constructor signature.

```ruby
class Projects::Create < ApplicationOperation
  def initialize(user:, attributes:)
    @user = user
    @attributes = attributes
  end

  def call
    # ...
  end
end
```

**Queries** (`app/queries/`) — filtering/searching/sorting; extend `ApplicationQuery`; keep controller filtering minimal; follow the naming pattern used by real query objects once they exist.

**Policies** (`app/policies/<resource>_policy.rb`) — `app/policies/project_policy.rb` → `ProjectPolicy`. Use `Policy::Scope` for collection visibility. Do not duplicate the same authorization rule across controller + operation + policy.

**Serializers** (`app/serializers/<resource>_serializer.rb`) — `project_serializer.rb` → `ProjectSerializer`. Output shape only — no mutations, authorization decisions, or workflows.

**Jobs** (`app/jobs/`) — action-descriptive names:

- `app/jobs/webhooks/deliver_job.rb` → `Webhooks::DeliverJob`
- `app/jobs/messages/retry_job.rb` → `Messages::RetryJob`

Load records and delegate complex logic to Operations — do not duplicate the whole workflow inside a job.

**Controllers** (`app/controllers/api/v1/`) — `app/controllers/api/v1/projects_controller.rb` → `API::V1::ProjectsController`. Responsibility: params, auth/authz entry, delegation, render. Reusable business logic must not live here.

**Models** (`app/models/`) — use for associations, validations, enums/status, truly model-level scopes, and small domain invariants. Do not turn models into large workflow objects.

**Specs mirror production structure** — a production file must have an obvious matching spec location:

- `app/operations/projects/create.rb` → `spec/operations/projects/create_spec.rb`
- `app/policies/project_policy.rb` → `spec/policies/project_policy_spec.rb`
- `app/jobs/webhooks/deliver_job.rb` → `spec/jobs/webhooks/deliver_job_spec.rb`
- `app/models/project.rb` → `spec/models/project_spec.rb`
- API controller behavior → `spec/requests/api/v1/...`

**Naming** — file name and Ruby constant must match Rails conventions; prefer descriptive action/domain names.

- Good: `Projects::Create`, `Projects::InviteCollaborator`, `Endpoints::RotateSecret`, `Messages::Replay`.
- Avoid vague names: `Helper`, `Manager`, `Processor`, `Handler`, `CommonService`, `Utility` — unless the repo already uses that concept and it is truly accurate.

**One responsibility per class** — the name should clearly explain what it does.

- Prefer: `Projects::Create`, `Endpoints::Archive`, `Events::Ingest`.
- Avoid: `ProjectManager`, `WebhookProcessor`, `CommonOperation`.

**New folder rule** — before creating a new top-level folder under `app/`: search the current repo, confirm the existing architecture cannot hold the code, explain why a new folder is needed, and get explicit approval. Do not introduce `app/services`, `app/interactors`, `app/use_cases`, `app/managers`, or `app/utils` without approval.

**Consistency before abstraction** — before creating a new class, inspect similar existing classes and match namespace, constructor style, `.call`/`#call`, error handling, serialization, spec style, and naming. Do not create a theoretically cleaner structure that is inconsistent with this repo.

**Self-review questions**

- Is every new file in the correct existing folder?
- Does the filename match the class/module name?
- Did I accidentally introduce a Service/Manager/Helper pattern?
- Is `initialize` actually necessary?
- Can another developer find the matching spec immediately?

## 5. API conventions

- Keep the API under **`/api/v1`** (`config/routes.rb`).
- Preserve the current JSON contracts:
  - resource → raw Blueprinter output;
  - error → `{ message, status, errors }` (validation errors as `[{ field, message }]`);
  - collection → `{ data, meta }` with Pagy pagination.
- Render only via `render_resource` / `render_resource_collection` / `render_resource_errors` (`app/controllers/concerns/jsonapi_render.rb`).
- Keep **Devise + devise-jwt + Allowlist revocation** (`config/initializers/devise.rb:322`, `app/models/user.rb:33`).
- The JWT stays in the **`Authorization`** response/request header (`config/initializers/cors.rb:12`).
- Pagination params: `params[:page][:number]` / `params[:page][:size]`, default 25 (`config/initializers/pagy.rb`).
- **Never weaken authentication or authorization** to make a feature work.

## 6. Project/Tenant security

- Treat **Project/Tenant ownership as a hard backend security boundary**.
- Every Project-scoped resource must verify access **server-side** in a policy / scope, not just in the controller action.
- Never rely on frontend restrictions.
- Prevent **cross-tenant access** even when IDs are changed manually — scope lookups through the current user (e.g. `current_user.projects.find(...)`, Pundit `Scope`), never `Model.find(params[:id])` for tenant data.

## 7. Database

- **Migrations only.** Never hand-edit `db/schema.rb`.
- **UUID primary keys** are the project convention (`config/initializers/generators.rb`, `db/schema.rb`).
- Add **FK / index / unique constraints** wherever correctness requires them.
- Never run destructive DB commands (`db:reset`, `db:drop`, data deletion) unless explicitly requested.
- For idempotency/concurrency, prefer **DB-level guarantees** (unique indexes, `upsert`, `ON CONFLICT`, row locks) where practical.

## 8. Background jobs

- Use `ApplicationJob` + **Sidekiq** (`config/initializers/sidekiq.rb`, `config/sidekiq.yml`).
- Use the **configured queues** only (`critical`, `default`, `low`) unless explicitly changing queue config.
- Jobs should be **idempotent** where practical.
- Webhook delivery/retry logic must tolerate **duplicate execution and worker restarts**.
- Be explicit about **retry, timeout, concurrency, and UTC** time behavior (store/compare in UTC).

## 9. Roadmap dependency awareness

- **Project + Collaborator** is the first core domain after auth.
- **Endpoint** depends on Project.
- **Event ingest** depends on Project + Endpoint.
- **Delivery / Retry / Circuit breaker / Replay** depend on the Message/Attempt lifecycle.
- **Dashboard / AI Diagnose** must **consume existing domain data**, not create parallel models.
- If a requested feature skips a required dependency, **explain it first** before implementing.

## 10. Testing

- Prefer **focused specs** for the code you touched.
- Follow the existing **RSpec + Rswag** patterns (`spec/requests/**` use `swagger_helper` + `run_test!`; models/policies/operations/jobs use type-tagged specs).
- **Mock external services** (SMTP, S3, third-party APIs).
- Do **not run the full suite** unless necessary or explicitly requested.
- Run **RuboCop** on touched code when practical.

**Spec structure**

- `describe` names the method / endpoint / behavior under test; `context` names a condition or scenario (prefer wording such as `when ...`, `with ...`, `without ...`); `it` states the expected observable result.
- In model specs, `describe` the specific behavior: `describe 'validations'` for validation rules, `describe '#instance_method'` for instance methods, `describe '.class_method'` for class methods, and `describe 'associations'` only when intentionally testing associations.
- Avoid vague or implementation-oriented `describe` names (e.g. `'user and project uniqueness'`, `'recipient validations'`, `'owner uniqueness'`). Move the specific condition into `context` (e.g. `describe 'validations'` + `context 'when the project already has an owner'`).
- Do **not** pile unrelated behaviors under one generic `describe`. Give each endpoint its own `describe`.
- Keep descriptions specific and readable, and reuse shared setup through `let` / `before` instead of repeating it.

```ruby
describe 'validations' do
  context 'when the name is missing' do
    it 'is invalid' do
      # ...
    end
  end
end

describe '#owner?' do
  context 'when the user is the project owner' do
    # ...
  end
end

describe 'GET /api/v1/projects', type: :request do
  context 'when the user is authenticated' do
    # ...
  end
end

describe NotificationsChannel, type: :channel do
  describe 'subscription' do
    context 'when the connection has a current user' do
      # ...
    end
  end
end

describe ProjectInvitations::Decline, type: :operation do
  describe '.call' do
    context 'when the invitation is pending' do
      # ...
    end
  end
end
```

**Enum specs**

- Do **not** write a spec whose only purpose is to assert a Rails enum declaration (e.g. that `status` contains `pending` / `accepted` / `cancelled`).
- Cover enum values indirectly through meaningful business behavior.
- Do not delete meaningful behavior specs just because they happen to use enum states.

**Explicit spec type**

- Declare the spec `type:` explicitly where a Rails type applies: `type: :model`, `type: :request`, `type: :channel`, `type: :policy`, `type: :job`, and `type: :controller` **only** when the repo actually has controller specs.
- Do not rely on `infer_spec_type_from_file_location!` — declare the type explicitly even when RSpec could infer it from the path.
- Do not invent a type that does not fit, and do not add controller specs just to satisfy this rule.
- For operations / queries there is no matching Rails type — follow the existing repo convention (`type: :operation` where already used, otherwise none).

**General**

- Avoid testing framework behavior Rails already guarantees; assert application/business behavior, plus the important failure and security paths.
- Do not add generated explanatory comments to specs — the `describe` / `context` / `it` names must tell the story.

## 11. Safety

- **Never expose** `.env`, credentials, secrets, signing keys, or `config/master.key`.
- **Never regenerate** Rails credentials or the master key (ignore the README `rm config/credentials.yml.enc` step unless explicitly asked).
- Do not copy boilerplate examples blindly.
- Do not fix unrelated code unless it blocks the requested task.

## 12. Git

- **Never commit or push** unless explicitly asked.
- If asked to commit, use a concise **single-line** commit message.
- **Never force-push.**

## 13. Working style

For implementation tasks, follow this order:

```
UNDERSTAND BUSINESS RULE
→ INSPECT CURRENT IMPLEMENTATION
→ FIND EXISTING PATTERN
→ DESIGN THE SMALLEST CONSISTENT CHANGE
→ IMPLEMENT IN THE CORRECT LAYER
→ WRITE SPECS THAT PROVE THE SAME BUSINESS RULE
→ TEST NARROWLY
→ SELF-REVIEW FOR DUPLICATION / ARCHITECTURE / SECURITY
→ REPORT EVIDENCE
```

## 14. Final report

After implementation, report:

- what changed
- files changed
- DB/API changes
- focused test results
- manual verification
- remaining risks / limitations
