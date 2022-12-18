#!/usr/bin/env fish

set -l _vault_item (op item get --vault "Infra" --account 27NCQVZT4VDCLHUIYSVI3GEQN4 --format json "Database - hdas" || exit 1)
set -l _admin_password (echo $_vault_item | jq '.fields[] | select(.id == "password") | .value' -r)

set -x DATABASE_URL postgres://hdas:$_admin_password@server:5432/hdas

sqlx database setup

