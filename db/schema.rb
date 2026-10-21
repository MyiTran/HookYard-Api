# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_10_20_120003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "allowlisted_jwts", force: :cascade do |t|
    t.string "jti", null: false
    t.string "aud"
    t.datetime "exp", null: false
    t.uuid "user_id", null: false
    t.index ["jti"], name: "index_allowlisted_jwts_on_jti", unique: true
    t.index ["user_id"], name: "index_allowlisted_jwts_on_user_id"
  end

  create_table "cable_tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_cable_tickets_on_expires_at"
    t.index ["token"], name: "index_cable_tickets_on_token", unique: true
    t.index ["user_id"], name: "index_cable_tickets_on_user_id"
  end

  create_table "delivery_attempts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "message_id", null: false
    t.integer "attempt_number", default: 1, null: false
    t.string "request_id", null: false
    t.string "webhook_id", null: false
    t.integer "signing_secret_version", null: false
    t.datetime "signed_at", null: false
    t.text "request_url", null: false
    t.string "http_method", default: "POST", null: false
    t.jsonb "request_headers", default: {}, null: false
    t.text "request_body", null: false
    t.integer "response_status"
    t.jsonb "response_headers"
    t.text "response_body"
    t.integer "duration_ms"
    t.string "error_type"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "attempt_number"], name: "index_delivery_attempts_on_message_id_and_attempt_number", unique: true
    t.index ["message_id", "created_at"], name: "index_delivery_attempts_on_message_id_and_created_at"
    t.index ["message_id"], name: "index_delivery_attempts_on_message_id"
    t.check_constraint "response_status IS NULL OR response_status >= 100 AND response_status <= 599", name: "delivery_attempts_response_status_range"
    t.check_constraint "signing_secret_version > 0", name: "delivery_attempts_signing_secret_version_positive"
  end

  create_table "endpoint_signing_secrets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "endpoint_id", null: false
    t.integer "version", null: false
    t.text "secret", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "retired_at"
    t.index ["endpoint_id", "version"], name: "index_endpoint_signing_secrets_on_endpoint_id_and_version", unique: true
    t.index ["endpoint_id"], name: "index_endpoint_signing_secrets_on_current_endpoint", unique: true, where: "(retired_at IS NULL)"
    t.index ["endpoint_id"], name: "index_endpoint_signing_secrets_on_endpoint_id"
  end

  create_table "endpoints", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.string "name", null: false
    t.string "url", null: false
    t.text "description"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "archived_at"
    t.string "event_types", default: [], null: false, array: true
    t.index ["archived_at"], name: "index_endpoints_on_archived_at"
    t.index ["project_id"], name: "index_endpoints_on_project_id"
    t.check_constraint "NOT ('*'::text = ANY (event_types::text[])) OR cardinality(event_types) = 1", name: "endpoints_wildcard_subscription_exclusive"
  end

  create_table "events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "idempotency_key", null: false
    t.string "idempotency_fingerprint", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "created_at"], name: "index_events_on_project_id_and_created_at"
    t.index ["project_id", "idempotency_key"], name: "index_events_on_project_id_and_idempotency_key", unique: true
    t.index ["project_id"], name: "index_events_on_project_id"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 255", name: "events_idempotency_key_length"
    t.check_constraint "jsonb_typeof(payload) = 'object'::text", name: "events_payload_is_object"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "event_id", null: false
    t.uuid "endpoint_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint_id", "created_at"], name: "index_messages_on_endpoint_id_and_created_at"
    t.index ["endpoint_id"], name: "index_messages_on_endpoint_id"
    t.index ["event_id", "endpoint_id"], name: "index_messages_on_event_id_and_endpoint_id", unique: true
    t.index ["event_id"], name: "index_messages_on_event_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'delivering'::character varying, 'succeeded'::character varying, 'failed'::character varying]::text[])", name: "messages_status_valid"
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "actor_id"
    t.uuid "project_id"
    t.uuid "project_invitation_id"
    t.string "kind", null: false
    t.string "title", null: false
    t.string "message", null: false
    t.string "target_url"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["project_id"], name: "index_notifications_on_project_id"
    t.index ["project_invitation_id"], name: "index_notifications_on_project_invitation_id"
    t.index ["user_id", "created_at"], name: "index_notifications_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "project_api_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "token_hint", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_project_api_credentials_on_project_id"
    t.index ["token_digest"], name: "index_project_api_credentials_on_token_digest", unique: true
  end

  create_table "project_invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.uuid "invited_by_id", null: false
    t.uuid "recipient_id", null: false
    t.string "role", default: "maintainer", null: false
    t.string "status", default: "pending", null: false
    t.datetime "accepted_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "declined_at"
    t.index ["invited_by_id"], name: "index_project_invitations_on_invited_by_id"
    t.index ["project_id", "recipient_id"], name: "index_project_invitations_pending_recipient", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["project_id"], name: "index_project_invitations_on_project_id"
    t.index ["recipient_id"], name: "index_project_invitations_on_recipient_id"
  end

  create_table "project_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.uuid "user_id", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "user_id"], name: "index_project_memberships_on_project_id_and_user_id", unique: true
    t.index ["project_id"], name: "index_project_memberships_on_project_id"
    t.index ["project_id"], name: "index_project_memberships_on_project_id_owner", unique: true, where: "((role)::text = 'owner'::text)"
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.string "resource_type"
    t.uuid "resource_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "resource_type", "resource_id"], name: "index_roles_on_name_and_resource_type_and_resource_id"
    t.index ["resource_type", "resource_id"], name: "index_roles_on_resource"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "first_name", default: "", null: false
    t.string "last_name", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "users_roles", id: false, force: :cascade do |t|
    t.uuid "user_id"
    t.uuid "role_id"
    t.index ["role_id"], name: "index_users_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_users_roles_on_user_id_and_role_id"
    t.index ["user_id"], name: "index_users_roles_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "allowlisted_jwts", "users", on_delete: :cascade
  add_foreign_key "cable_tickets", "users", on_delete: :cascade
  add_foreign_key "delivery_attempts", "messages", on_delete: :cascade
  add_foreign_key "endpoint_signing_secrets", "endpoints", on_delete: :cascade
  add_foreign_key "endpoints", "projects", on_delete: :cascade
  add_foreign_key "events", "projects", on_delete: :cascade
  add_foreign_key "messages", "endpoints", on_delete: :cascade
  add_foreign_key "messages", "events", on_delete: :cascade
  add_foreign_key "notifications", "project_invitations", on_delete: :cascade
  add_foreign_key "notifications", "projects", on_delete: :cascade
  add_foreign_key "notifications", "users", column: "actor_id", on_delete: :cascade
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "project_api_credentials", "projects", on_delete: :cascade
  add_foreign_key "project_invitations", "projects", on_delete: :cascade
  add_foreign_key "project_invitations", "users", column: "invited_by_id", on_delete: :cascade
  add_foreign_key "project_invitations", "users", column: "recipient_id", on_delete: :cascade
  add_foreign_key "project_memberships", "projects", on_delete: :cascade
  add_foreign_key "project_memberships", "users", on_delete: :cascade
end
