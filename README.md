# DNCC-ETL-2026

> **Pipeline ETL para el INGEI sector AFOLU del Paraguay**  
> Generación automatizada de Tablas Comunes de Reporte (CRT) para la plataforma ETF de la CMNUCC — Primer y Segundo Informe Bienal de Transparencia (1BTR/2BTR) y 5ª Comunicación Nacional.

[![Proyecto](https://img.shields.io/badge/Proyecto-N°%2001000367-1D6A3A)](https://unfccc.int/transparency-and-reporting)
[![CMNUCC ETF](https://img.shields.io/badge/CMNUCC-ETF%20Reporting%20Tools-0055A5)](https://unfccc.int/etf-reporting-tools-help)
[![Python](https://img.shields.io/badge/Python-3.10-3776AB)](https://www.python.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791)](https://www.postgresql.org/)
[![Licencia](https://img.shields.io/badge/Licencia-MADES%20%2F%20Proyecto%2001000367-lightgrey)](#licencia)

---

## Contexto

Paraguay tiene la obligación de presentar Tablas Comunes de Reporte (CRT) ante la CMNUCC en el marco del Acuerdo de París. Los sectores **Energy, IPPU y Residuos** generan sus datos mediante el [Software IPCC](https://www.ipcc-nggip.iges.or.jp/public/inventorysoftware.html) y los cargan como archivos JSON en la plataforma [ETF Reporting Tools](https://unfccc.int/etf-reporting-tools-help). Sin embargo, el sector **AFOLU** (Agricultura, Silvicultura y Otros Usos de la Tierra) no contaba con este flujo: sus datos eran incorporados manualmente al Excel CRT por la especialista sectorial.

**Este repositorio implementa el pipeline ETL que elimina ese proceso manual**, generando un JSON AFOLU compatible con la plataforma ETF y unificándolo con los demás sectores.

```
Antes:  JSON otros sectores → ETF Reporting Tools → CRT.xlsx → [edición manual AFOLU]
Ahora:  GEE/AFOLU → ETL Python → JSON AFOLU ─┐
        JSON Energy/IPPU/Waste ───────────────┴→ etf-cli → ETF Reporting Tools → CRT automatizado
```

---

## Arquitectura del pipeline

El pipeline está organizado en notebooks numerados (`ETL_00` a `ETL_06`), cada uno con responsabilidad única e idempotente (puede re-ejecutarse sin efectos colaterales):

```
ETL_00  Schema SQL         ──►  PostgreSQL 16 (4 schemas, 16 tablas, 3 vistas)
ETL_01  Test de conexión   ──►  Verificación Python ↔ PostgreSQL (psycopg2 + SQLAlchemy)
ETL_02  Variables AFOLU    ──►  dim_variables_etf: 32.694 UIDs (Agriculture + LULUCF)
ETL_02b Variables otros    ──►  dim_variables_etf: +38.918 UIDs (Energy + IPPU + Waste)
ETL_03  JSONs 1BTR         ──►  staging.raw_sector_json + fact_valores_etf
ETL_04  Excel AFOLU        ──►  staging.raw_afolu_datos → fact_datos_actividad
ETL_05  Genera JSON AFOLU  ──►  etf_output.json_generados
ETL_06  Merge + validación ──►  JSON unificado 4 sectores + etf-cli fix -r ALL
```

---

## Estructura del repositorio

```
dncc-etl-2026/
│
├── ETL_00_ingei_afolu_schema_v2.sql          # DDL completo: schemas, tablas, índices, triggers
├── ETL_01_conexion_test.ipynb                # Test de conexión y auditoría inicial
├── ETL_02_poblar_dim_variables_etf_v2.ipynb  # Carga catálogo AFOLU (Agriculture + LULUCF)
├── ETL_02b_poblar_dim_variables_etf_otros_sectores.ipynb  # Append Energy/IPPU/Waste
├── ETL_03_cargar_json_sectoriales.ipynb      # Carga JSONs 1BTR a staging + fact
├── ETL_04_cargar_excel_afolu.ipynb           # Ingesta Excel estandarizado AFOLU
├── ETL_05_generar_json_afolu.ipynb           # Generación JSON AFOLU desde BD
├── ETL_06_merge_validacion.ipynb             # Unificación JSON + validación etf-cli
│
├── in/                                       # Datos de entrada
│   ├── metadata.json.lzma                    # Catálogo oficial ETF (etf-cli v1.30.4, 71.612 UIDs)
│   ├── crt_ener_90-21.json                   # JSON Energy 1BTR (existente)
│   ├── crt_ippu_90-21.json                   # JSON IPPU 1BTR (existente)
│   ├── crt_resi_90-21.json                   # JSON Residuos 1BTR (existente)
│   └── 01_INGEI_DatosPrimarios_AFOLU.xlsx    # Excel estandarizado AFOLU (Especialista AFOLU)
│
└── out/                                      # Outputs generados

```


---

## Esquema de base de datos

El pipeline opera sobre el schema `ingei_afolu` en PostgreSQL 16, organizado en cuatro namespaces con separación de responsabilidades:

| Schema | Responsabilidad | Tablas clave |
|---|---|---|
| `staging` | Datos crudos, sin transformar | `raw_sector_json`, `raw_afolu_datos` |
| `inventario` | Datos normalizados del INGEI | `dim_versiones`, `dim_variables_etf`, `fact_valores_etf`, `fact_datos_actividad` |
| `etf_output` | JSONs listos para ETF Reporting Tools | `json_generados` |
| `auditoria` | Trazabilidad según [ISO/IEC 25012:2008](https://www.iso.org/standard/35736.html) | `log_pipeline`, `control_calidad` |

### Versiones del inventario (`dim_versiones`)

Cada reporte ante la CMNUCC recalcula la **serie completa desde 1990**. El `version_id` en las tablas de hechos separa estas series sin necesidad de cruzarlas:

| version_id | Reporte | Serie cubierta | Estado |
|---|---|---|---|
| 1 | 3IBA | 1990–2017 | Histórico |
| 2 | 4CN | 1990–2019 | Histórico |
| 3 | 1BTR | 1990–2021 | En proceso |
| 4 | 2BTR | 1990–2024 | Pendiente |

---

## Prerrequisitos

```bash
# Entorno
Python 3.10
PostgreSQL 16

# Paquetes Python
pip install psycopg2-binary sqlalchemy pandas jupyter

# ETF CLI (para validación en ETL_06)
# https://github.com/unfccc/etf-cli
# v1.30.4 — incluye metadata.json.lzma con 71.612 variable_uid
```


---

## Uso

### 1. Crear el schema

```bash
psql -U tu_usuario -d ingei_afolu -f ETL_00_ingei_afolu_schema_v2.sql
```

### 2. Ejecutar los notebooks en orden

```bash
jupyter nbconvert --to notebook --execute ETL_01_conexion_test.ipynb
jupyter nbconvert --to notebook --execute ETL_02_poblar_dim_variables_etf_v2.ipynb
jupyter nbconvert --to notebook --execute ETL_02b_poblar_dim_variables_etf_otros_sectores.ipynb
# ... continuar con ETL_03 al ETL_06
```

O abrirlos directamente en Jupyter y ejecutar celda a celda (recomendado para ETL_03+, que incluyen lógica de retry y logging).

### 3. Validar el JSON generado (ETL_06)

```bash
etf data fix -r ALL out/crt_unified_90-21.json
```

---

## Decisiones de diseño

**¿Por qué notebooks y no scripts?**  
Los notebooks permiten ejecución parcial, inspección de resultados intermedios y documentación inline. 
El pipeline es exploratorio en esta fase; los ETL_04–06 migrarán a scripts cuando la estructura del Excel AFOLU se estabilice.

**¿Por qué upsert idempotente?**  
`INSERT ... ON CONFLICT DO UPDATE` garantiza que cualquier re-ejecución (por corrección de bug, cambio en fuente de datos, o nuevo año de inventario) produce el mismo resultado sin duplicados ni borrado previo.

**¿Por qué `version_id` en las tablas de hechos?**  
Cada reporte ante la CMNUCC recalcula la serie completa desde 1990 con metodología actualizada. Separar por `version_id` permite mantener series históricas sin contaminarlas con recálculos del período vigente.

**¿Por qué PostgreSQL y no SQLite o un DataFrame?**  
El catálogo de variables ETF tiene 71.612 filas; la tabla de hechos de un solo sector (Energy, 32 años) tiene 304.544 entradas. El volumen total proyectado para AFOLU supera los 10 millones de registros. PostgreSQL maneja esto de manera robusta con índices y constraints de integridad referencial.

---

## Estado del pipeline

| Notebook | Estado | Resultado |
|---|---|---|
| ETL_00 | ✅ Completo | 4 schemas · 16 tablas · 35 años · 4 versiones |
| ETL_01 | ✅ Completo | Conexión verificada (psycopg2 68.9 ms · SQLAlchemy) |
| ETL_02 | ✅ Completo | 32.694 variables AFOLU (4.435 Agriculture + 28.259 LULUCF) |
| ETL_02b | ✅ Completo | +38.918 variables → catálogo ETF completo: 71.612 UIDs |
| ETL_03 | ⏳ En curso | Bug float64/None pandas resuelto en v2; confirmación pendiente |
| ETL_04 | ⏳ Pendiente | Diseño declarativo listo; pendiente estabilización del Excel AFOLU |
| ETL_05 | ⏳ Pendiente | — |
| ETL_06 | ⏳ Pendiente | — |

---

## Recursos técnicos

| Recurso | URL |
|---|---|
| ETF Reporting Tools (CMNUCC) | https://unfccc.int/etf-reporting-tools-help |
| etf-cli (herramienta de validación) | https://github.com/unfccc/etf-cli |
| Documentación técnica ETF | https://unfccc.int/etf-reporting-tools-help#Technical |
| IPCC 2006 Guidelines Vol. 4 (AFOLU) | https://www.ipcc-nggip.iges.or.jp/public/2006gl/vol4.html |
| IPCC 2019 Refinement Vol. 4 | https://www.ipcc-nggip.iges.or.jp/public/2019rf/vol4.html |
| ISO/IEC 25012:2008 (Data Quality) | https://www.iso.org/standard/35736.html |
| Google Earth Engine | https://earthengine.google.com/ |
| hmmlearn (postprocesamiento HMM) | https://hmmlearn.readthedocs.io/ |
| AcATaMa — QGIS plugin (muestreo EET) | https://github.com/SMByC/AcATaMa |

---

## Desarrollo
```
Palacios, C. N. (2026). dncc-etl-2026: Pipeline ETL para el INGEI sector AFOLU del Paraguay 
— generación automatizada de CRT para la plataforma ETF de la CMNUCC (1BTR/2BTR). 
Proyecto N° 01000367, MADES/DNCC, Asunción, Paraguay. 
https://github.com/cpalacios01/dncc-etl-2026
```

---

## Licencia

Desarrollado en el marco del **Proyecto N° 01000367** — "Primer y Segundo Informe Bienal de Transparencia y Quinta Comunicación Nacional 1BTR + 5NC/2BTR", Ministerio del Ambiente y Desarrollo Sostenible (MADES), Dirección Nacional de Cambio Climático (DNCC), Paraguay.

Los notebooks y el esquema SQL son de uso institucional bajo las condiciones del contrato de consultoría. Para consultas sobre reutilización, contactar a la DNCC/MADES.
