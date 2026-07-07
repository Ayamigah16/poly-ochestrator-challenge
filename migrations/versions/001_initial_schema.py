"""Initial schema: query_records and brand_metrics tables

Revision ID: 001
Revises:
Create Date: 2026-06-22

"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "query_records",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("brand", sa.String(200), nullable=False),
        sa.Column("query", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("mention_rate", sa.Float(), nullable=False, server_default="0.0"),
        sa.Column("average_rank", sa.Float(), nullable=True),
        sa.Column("average_sentiment", sa.Float(), nullable=False, server_default="0.0"),
        sa.Column("adapter_responses", sa.JSON(), nullable=False),
        sa.Column("mention_results", sa.JSON(), nullable=False),
        sa.Column("competitors", sa.JSON(), nullable=False),
        sa.Column("succeeded_adapters", sa.JSON(), nullable=False),
        sa.Column("failed_adapters", sa.JSON(), nullable=False),
    )
    op.create_index("ix_query_records_brand", "query_records", ["brand"])
    op.create_index("ix_query_records_created_at", "query_records", ["created_at"])

    op.create_table(
        "brand_metrics",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("brand", sa.String(200), nullable=False),
        sa.Column("metric_date", sa.DateTime(timezone=True), nullable=False),
        sa.Column("total_queries", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("avg_mention_rate", sa.Float(), nullable=False, server_default="0.0"),
        sa.Column("avg_rank", sa.Float(), nullable=True),
        sa.Column("avg_sentiment", sa.Float(), nullable=False, server_default="0.0"),
        sa.Column("best_adapter", sa.String(50), nullable=True),
    )
    op.create_index("ix_brand_metrics_brand", "brand_metrics", ["brand"])
    op.create_index("ix_brand_metrics_date", "brand_metrics", ["metric_date"])


def downgrade() -> None:
    op.drop_table("brand_metrics")
    op.drop_table("query_records")
