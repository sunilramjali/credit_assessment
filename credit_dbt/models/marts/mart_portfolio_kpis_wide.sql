{% set kpis = kpi_definitions() %}

{#
    One row, one column per KPI. This is the shape a BI scorecard needs: each
    card points at its own field, so each field carries its own data type and
    its own formatting.

    This model is a pure pivot of `mart_portfolio_kpis` and computes nothing of
    its own. Every number is defined once, in the long model, and both shapes
    loop over the same `kpi_definitions()` macro — so the two marts cannot
    disagree about a value or drift apart on which KPIs exist.

    Each unit is given its real type here, which the long model cannot do
    because there every value shares one `double` column. Counts become BIGINT
    so a report shows 10,000 rather than 10000.0, and amounts become
    DECIMAL(18, 2) so currency carries no float tail. That rounding is
    deliberate and belongs to presentation only — the long model keeps full
    precision for analysis.
#}

with kpis_long as (

    select
        kpi_name,
        kpi_value,
        kpi_value_text

    from {{ ref('mart_portfolio_kpis') }}

),

pivoted as (

    select

        {% for kpi in kpis %}

            max(
                case
                    when kpi_name = '{{ kpi.name }}'
                        {% if kpi.unit == 'date' %}
                            then cast(kpi_value_text as date)
                        {% elif kpi.unit == 'count' %}
                            then cast(kpi_value as bigint)
                        {% elif kpi.unit == 'amount' %}
                            then cast(kpi_value as decimal(18, 2))
                        {% else %}
                            then kpi_value
                        {% endif %}
                end
            ) as {{ kpi.name }}{% if not loop.last %},{% endif %}

        {% endfor %}

    from kpis_long

)

select *
from pivoted
