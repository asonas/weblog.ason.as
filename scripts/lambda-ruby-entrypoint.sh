#!/bin/sh
set -eu

export _HANDLER="${1:?Lambda handler is required}"
exec aws_lambda_ric
