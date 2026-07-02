-- ============================================================
-- INGEI AFOLU – Schema PostgreSQL
-- DNCC / MADES – Paraguay
-- Proyecto N° 01000367
-- v2: corrige dim_versiones para reflejar los reportes reales
--     presentados por Paraguay (ver bloque "DATOS INICIALES")
-- ============================================================
-- Convenciones:
--   Schemas: staging | inventario | etf_output | auditoria
--   PKs:     serial (bigint) con nombre <tabla>_id
--   FKs:     <tabla_ref>_id
--   Fechas:  timestamptz para todo lo que tenga hora
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- SCHEMAS
-- ────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS inventario;
CREATE SCHEMA IF NOT EXISTS etf_output;
CREATE SCHEMA IF NOT EXISTS auditoria;

-- ============================================================
-- SCHEMA: staging
-- Datos crudos sin transformar. Punto de entrada del pipeline.
-- ============================================================

-- Carga cruda del Excel estandarizado AFOLU (Datos_INGEI)
CREATE TABLE staging.raw_afolu_datos (
    id                   BIGSERIAL PRIMARY KEY,
    anho                 INTEGER,
    departamento         TEXT,
    municipio            TEXT,
    sector_ipcc          TEXT,              -- 'Agricultura' | 'UTCUTS'
    categoria_nivel1     TEXT,              -- '3.A Fermentación entérica'
    categoria_nivel2     TEXT,
    categoria_nivel3     TEXT,
    codigo_ipcc          TEXT,              -- '3.A.1.a'
    tier1_2              TEXT,
    dato_actividad       NUMERIC,
    unidad_actividad     TEXT,
    tipo_dato_actividad  TEXT,
    -- metadatos de carga
    archivo_origen       TEXT,
    cargado_en           TIMESTAMPTZ DEFAULT now(),
    id_lote_carga        UUID DEFAULT gen_random_uuid()
);

-- Datos climáticos auxiliares (Datos_Clima del Excel)
CREATE TABLE staging.raw_clima_datos (
    id                            BIGSERIAL PRIMARY KEY,
    anho                          INTEGER,
    departamento                  TEXT,
    municipio                     TEXT,
    temperatura_media_anual       NUMERIC,
    temperatura_maxima_media      NUMERIC,
    temperatura_minima_media      NUMERIC,
    precipitacion_anual           NUMERIC,
    precipitacion_estacion_lluviosa NUMERIC,
    precipitacion_estacion_seca   NUMERIC,
    humedad_relativa_media        NUMERIC,
    evapotranspiracion_potencial  NUMERIC,
    evapotranspiracion_real       NUMERIC,
    cargado_en                    TIMESTAMPTZ DEFAULT now()
);

-- JSON de otros sectores tal como vienen del software IPCC
-- Energy, IPPU, Waste – 1990-2021 (y futuras actualizaciones)
CREATE TABLE staging.raw_sector_json (
    id              BIGSERIAL PRIMARY KEY,
    sector          TEXT NOT NULL,         -- 'energy' | 'ippu' | 'waste' | 'agriculture' | 'lulucf'
    anho_desde      INTEGER,               -- año mínimo cubierto por el JSON
    anho_hasta      INTEGER,               -- año máximo cubierto por el JSON
    metadata_ver    TEXT,                  -- version.metadata_ver del JSON
    data_version    TEXT,                  -- version.data_version
    contenido       JSONB NOT NULL,        -- JSON completo
    archivo_origen  TEXT,
    cargado_en      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON staging.raw_sector_json (sector);

-- ============================================================
-- SCHEMA: inventario
-- Dimensiones y hechos normalizados. Fuente de verdad.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- DIMENSIONES
-- ────────────────────────────────────────────────────────────

CREATE TABLE inventario.dim_versiones (
    version_id      SERIAL PRIMARY KEY,
    nombre_version  TEXT NOT NULL UNIQUE,  -- '3IBA', '4CN', '1BTR', '2BTR', ...
    anho_base_desde INTEGER NOT NULL,
    anho_base_hasta INTEGER NOT NULL,
    activa          BOOLEAN NOT NULL DEFAULT FALSE,
    descripcion     TEXT,
    creada_en       TIMESTAMPTZ DEFAULT now()
);
-- Solo una versión activa a la vez
CREATE UNIQUE INDEX dim_versiones_activa_uq
    ON inventario.dim_versiones (activa) WHERE activa = TRUE;

-- Stored procedure para activar una versión (igual al que ya tenés)
CREATE OR REPLACE PROCEDURE inventario.sp_activar_version(p_version_id INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventario.dim_versiones SET activa = FALSE;
    UPDATE inventario.dim_versiones SET activa = TRUE
    WHERE version_id = p_version_id;
END;
$$;

-- Años del inventario
CREATE TABLE inventario.dim_anhos (
    anho_id     SERIAL PRIMARY KEY,
    anho        INTEGER NOT NULL UNIQUE CHECK (anho BETWEEN 1990 AND 2100)
);
INSERT INTO inventario.dim_anhos (anho)
SELECT generate_series(1990, 2024);

-- Departamentos de Paraguay
CREATE TABLE inventario.dim_departamentos (
    departamento_id  SERIAL PRIMARY KEY,
    codigo_dep       CHAR(2) UNIQUE,       -- código INE 2 dígitos
    nombre           TEXT NOT NULL UNIQUE,
    region           TEXT                  -- Oriental | Occidental
);
INSERT INTO inventario.dim_departamentos (codigo_dep, nombre, region) VALUES
('01','Concepción','Oriental'),('02','San Pedro','Oriental'),
('03','Cordillera','Oriental'),('04','Guairá','Oriental'),
('05','Caaguazú','Oriental'),('06','Caazapá','Oriental'),
('07','Itapúa','Oriental'),('08','Misiones','Oriental'),
('09','Paraguarí','Oriental'),('10','Alto Paraná','Oriental'),
('11','Central','Oriental'),('12','Ñeembucú','Oriental'),
('13','Amambay','Oriental'),('14','Canindeyú','Oriental'),
('15','Presidente Hayes','Occidental'),('16','Alto Paraguay','Occidental'),
('17','Boquerón','Occidental');

-- Gases GEI
CREATE TABLE inventario.dim_gases (
    gas_id   SERIAL PRIMARY KEY,
    codigo   TEXT NOT NULL UNIQUE,    -- 'CO2' | 'CH4' | 'N2O' | 'GHG_AGG'
    nombre   TEXT NOT NULL,
    nombre_etf TEXT                   -- nombre exacto en ETF: 'CO₂', 'CH₄', 'N₂O', 'Aggregate GHGs'
);
INSERT INTO inventario.dim_gases (codigo, nombre, nombre_etf) VALUES
('CO2',    'Dióxido de carbono',          'CO₂'),
('CH4',    'Metano',                       'CH₄'),
('N2O',    'Óxido nitroso',               'N₂O'),
('GHG_AGG','Gases de efecto invernadero agregados', 'Aggregate GHGs');

-- Árbol de categorías IPCC para AFOLU
CREATE TABLE inventario.dim_categorias_ipcc (
    categoria_id     SERIAL PRIMARY KEY,
    codigo_ipcc      TEXT NOT NULL UNIQUE,  -- '3.A.1.a', '4.A.1', etc.
    sector           TEXT NOT NULL,          -- 'Agricultura' | 'UTCUTS'
    nivel            INTEGER NOT NULL CHECK (nivel BETWEEN 1 AND 4),
    nombre_es        TEXT NOT NULL,
    nombre_etf       TEXT,                   -- nombre en ETF metadata
    codigo_padre     TEXT REFERENCES inventario.dim_categorias_ipcc(codigo_ipcc),
    activa           BOOLEAN DEFAULT TRUE
);
-- Índices para navegación del árbol
CREATE INDEX ON inventario.dim_categorias_ipcc (codigo_padre);
CREATE INDEX ON inventario.dim_categorias_ipcc (sector);

-- Diccionario de variable_uid ETF (parseado del metadata.json.lzma del etf-cli)
-- Esta tabla es el puente central del pipeline: código IPCC + medida + gas → variable_uid
CREATE TABLE inventario.dim_variables_etf (
    variable_etf_id  SERIAL PRIMARY KEY,
    variable_uid     UUID NOT NULL UNIQUE,   -- UID exacto del ETF
    codigo_ipcc      TEXT,                   -- '3.A.1.a' (puede ser NULL si es subcategoría sin código directo)
    nombre_completo  TEXT NOT NULL,          -- nombre parseado del metadata ETF
    medida           TEXT NOT NULL,          -- 'Emissions' | 'Activity Data' | 'Implied emission factor' | etc.
    gas_codigo       TEXT,                   -- 'CO2' | 'CH4' | 'N2O' | 'GHG_AGG'
    parametro        TEXT,                   -- 'no parameter' | 'Population' | etc.
    unidad           TEXT,                   -- 'kt' | 'ha' | '1000s' | etc.
    sector           TEXT,                   -- 'agriculture' | 'lulucf'
    es_calculada     BOOLEAN DEFAULT FALSE,  -- is_calculated del metadata
    es_editable      BOOLEAN DEFAULT TRUE,   -- is_editable del metadata
    nke_permitido    BOOLEAN DEFAULT TRUE,   -- nke_allowed (permite NK/NE/NO)
    node_uid         UUID,                   -- node_uid del metadata
    metadata_ver     TEXT DEFAULT '1.30.4',  -- versión del metadata ETF usado
    -- CONSTRAINT para asegurar que podemos hacer el join
    CONSTRAINT ck_variables_etf_sector
        CHECK (sector IN ('agriculture','lulucf','energy','ippu','waste'))
);
CREATE INDEX ON inventario.dim_variables_etf (codigo_ipcc);
CREATE INDEX ON inventario.dim_variables_etf (sector, medida);
CREATE INDEX ON inventario.dim_variables_etf (gas_codigo);

-- Tipos de dato de actividad (controlado para join con Excel)
CREATE TABLE inventario.dim_tipos_dato (
    tipo_dato_id  SERIAL PRIMARY KEY,
    codigo        TEXT NOT NULL UNIQUE,  -- 'DA_CABEZAS' | 'DA_HA' | 'FE_CH4' | 'EMISION'
    descripcion   TEXT NOT NULL,
    unidad_base   TEXT                   -- unidad canónica
);

-- ────────────────────────────────────────────────────────────
-- HECHOS
-- ────────────────────────────────────────────────────────────

-- Datos de actividad y factores de emisión AFOLU por año y departamento
-- Origen: Excel estandarizado de Luisa / especialistas
CREATE TABLE inventario.fact_datos_actividad (
    dato_actividad_id  BIGSERIAL PRIMARY KEY,
    version_id         INTEGER NOT NULL REFERENCES inventario.dim_versiones(version_id),
    anho_id            INTEGER NOT NULL REFERENCES inventario.dim_anhos(anho_id),
    departamento_id    INTEGER REFERENCES inventario.dim_departamentos(departamento_id),
    categoria_id       INTEGER NOT NULL REFERENCES inventario.dim_categorias_ipcc(categoria_id),
    -- valor medido
    tipo_dato          TEXT NOT NULL,          -- 'dato_actividad' | 'factor_emision' | 'emision'
    valor              NUMERIC,
    unidad             TEXT NOT NULL,
    -- metodología
    tier               TEXT,                   -- 'T1' | 'T2' | 'T1a' | 'T2a'
    fuente             TEXT,                   -- 'MAG/DCEA' | 'SENACSA' | 'GEE/S2' | etc.
    metodo_empalme     TEXT,                   -- 'interpolacion' | 'varianza' | etc.
    -- trazabilidad a staging
    id_lote_carga      UUID,
    cargado_en         TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT uq_fact_da UNIQUE (version_id, anho_id, departamento_id, categoria_id, tipo_dato)
);
CREATE INDEX ON inventario.fact_datos_actividad (version_id, anho_id);
CREATE INDEX ON inventario.fact_datos_actividad (categoria_id);

-- Valores de variables ETF para todos los sectores (incluye Energy/IPPU/Waste del JSON histórico)
-- Estructura 1:1 con data.values[] del JSON ETF, pero normalizada y consultable
CREATE TABLE inventario.fact_valores_etf (
    valor_etf_id     BIGSERIAL PRIMARY KEY,
    version_id       INTEGER NOT NULL REFERENCES inventario.dim_versiones(version_id),
    variable_etf_id  INTEGER NOT NULL REFERENCES inventario.dim_variables_etf(variable_etf_id),
    anho_id          INTEGER NOT NULL REFERENCES inventario.dim_anhos(anho_id),
    -- valor
    valor_tipo       TEXT NOT NULL CHECK (valor_tipo IN ('numeric','NK','dropdown')),
    valor_numerico   NUMERIC,                  -- cuando valor_tipo = 'numeric'
    valor_nk         INTEGER,                  -- código NK (32, 256, 512, 1024, 2048) cuando tipo = 'NK'
    valor_dropdown   TEXT,                     -- cuando tipo = 'dropdown'
    descripcion      TEXT,                     -- campo description opcional del JSON
    -- trazabilidad
    origen           TEXT NOT NULL,            -- 'json_software' | 'etl_afolu' | 'manual'
    cargado_en       TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT uq_fact_valores UNIQUE (version_id, variable_etf_id, anho_id)
);
CREATE INDEX ON inventario.fact_valores_etf (version_id, anho_id);
CREATE INDEX ON inventario.fact_valores_etf (variable_etf_id);
-- Índice parcial para consultas rápidas de valores numéricos
CREATE INDEX ON inventario.fact_valores_etf (anho_id, valor_numerico)
    WHERE valor_tipo = 'numeric';

-- Tabla de referencia de valores NK (decodificación de códigos bitmask)
-- Los valores 32, 256, 512, 1024, 2048 son flags del ETF
CREATE TABLE inventario.ref_nk_codigos (
    codigo_nk    INTEGER PRIMARY KEY,
    significado  TEXT NOT NULL,    -- 'NA' | 'NE' | 'NO' | 'IE' | 'C'
    descripcion  TEXT NOT NULL
);
INSERT INTO inventario.ref_nk_codigos VALUES
(8,      'C',   'Confidential'),
(32,     'NA',  'Not Applicable'),
(256,    'NO',  'Not Occurring'),
(512,    'NE',  'Not Estimated'),
(1024,   'IE',  'Included Elsewhere'),
(2048,   'C',   'Confidential (extended)'),
(131072, 'C',   'Confidential (flag alt)');

-- ============================================================
-- SCHEMA: etf_output
-- JSON generados listos para importar en ETF Reporting Tools
-- ============================================================

CREATE TABLE etf_output.json_generados (
    json_id          BIGSERIAL PRIMARY KEY,
    version_id       INTEGER NOT NULL REFERENCES inventario.dim_versiones(version_id),
    sector           TEXT NOT NULL,            -- 'afolu' | 'energy' | 'ippu' | 'waste' | 'unified'
    anho_desde       INTEGER NOT NULL,
    anho_hasta       INTEGER NOT NULL,
    metadata_ver_etf TEXT NOT NULL,            -- versión del metadata ETF usado para generar
    contenido        JSONB NOT NULL,           -- el JSON generado
    checksum_sha256  TEXT,                     -- hash del contenido para detección de cambios
    estado           TEXT NOT NULL DEFAULT 'borrador'
        CHECK (estado IN ('borrador','validado_cli','importado_etf','con_errores')),
    errores_cli      JSONB,                    -- output del etf data fix si hubo errores
    generado_en      TIMESTAMPTZ DEFAULT now(),
    generado_por     TEXT
);
CREATE INDEX ON etf_output.json_generados (version_id, sector, estado);

-- ============================================================
-- SCHEMA: auditoria
-- Trazabilidad completa del pipeline
-- ============================================================

CREATE TABLE auditoria.log_pipeline (
    log_id        BIGSERIAL PRIMARY KEY,
    etapa         TEXT NOT NULL,    -- 'ingest_excel' | 'ingest_json' | 'transform' | 'generate_json' | 'fix_cli' | 'import_etf'
    version_id    INTEGER,
    sector        TEXT,
    resultado     TEXT NOT NULL CHECK (resultado IN ('ok','warning','error')),
    mensaje       TEXT,
    detalle       JSONB,            -- errores detallados, conteos, etc.
    duracion_ms   INTEGER,
    ejecutado_en  TIMESTAMPTZ DEFAULT now(),
    ejecutado_por TEXT DEFAULT current_user
);
CREATE INDEX ON auditoria.log_pipeline (etapa, resultado);
CREATE INDEX ON auditoria.log_pipeline (ejecutado_en DESC);

-- Control de calidad ISO/IEC 25012
CREATE TABLE auditoria.control_calidad (
    control_id         BIGSERIAL PRIMARY KEY,
    version_id         INTEGER REFERENCES inventario.dim_versiones(version_id),
    anho_id            INTEGER REFERENCES inventario.dim_anhos(anho_id),
    sector             TEXT,
    dimension_calidad  TEXT NOT NULL,  -- 'completitud' | 'consistencia' | 'exactitud' | 'actualidad'
    indicador          TEXT NOT NULL,  -- ej: 'pct_valores_nulos' | 'sum_ha_vs_total'
    valor_obtenido     NUMERIC,
    umbral_aceptable   NUMERIC,
    aprobado           BOOLEAN,
    observacion        TEXT,
    evaluado_en        TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- VISTAS ÚTILES
-- ============================================================

-- Vista para navegar emisiones AFOLU con nombres legibles
CREATE OR REPLACE VIEW inventario.v_emisiones_afolu AS
SELECT
    dv.nombre_version,
    da.anho_id,
    di.anho,
    dep.nombre          AS departamento,
    cat.codigo_ipcc,
    cat.nombre_es       AS categoria,
    cat.sector,
    da.tipo_dato,
    da.valor,
    da.unidad,
    da.tier,
    da.fuente
FROM inventario.fact_datos_actividad da
JOIN inventario.dim_versiones       dv  ON dv.version_id   = da.version_id
JOIN inventario.dim_anhos           di  ON di.anho_id      = da.anho_id
LEFT JOIN inventario.dim_departamentos dep ON dep.departamento_id = da.departamento_id
JOIN inventario.dim_categorias_ipcc cat ON cat.categoria_id = da.categoria_id;

-- Vista para valores ETF con decodificación de NK
CREATE OR REPLACE VIEW inventario.v_valores_etf_decodificados AS
SELECT
    dv.nombre_version,
    di.anho,
    ve.codigo_ipcc,
    ve.medida,
    ve.gas_codigo,
    ve.unidad,
    fv.valor_tipo,
    CASE
        WHEN fv.valor_tipo = 'numeric'  THEN fv.valor_numerico::TEXT
        WHEN fv.valor_tipo = 'NK'       THEN nk.significado
        WHEN fv.valor_tipo = 'dropdown' THEN fv.valor_dropdown
    END                                     AS valor_display,
    fv.valor_numerico,
    fv.origen
FROM inventario.fact_valores_etf          fv
JOIN inventario.dim_versiones             dv  ON dv.version_id      = fv.version_id
JOIN inventario.dim_anhos                 di  ON di.anho_id         = fv.anho_id
JOIN inventario.dim_variables_etf         ve  ON ve.variable_etf_id = fv.variable_etf_id
LEFT JOIN inventario.ref_nk_codigos       nk  ON nk.codigo_nk       = fv.valor_nk;

-- Vista de cobertura del inventario (qué años/sectores tenemos cargados)
CREATE OR REPLACE VIEW etf_output.v_cobertura_inventario AS
SELECT
    dv.nombre_version,
    ve.sector,
    MIN(di.anho) AS anho_desde,
    MAX(di.anho) AS anho_hasta,
    COUNT(DISTINCT di.anho) AS anhos_cubiertos,
    COUNT(*) FILTER (WHERE fv.valor_tipo = 'numeric') AS valores_numericos,
    COUNT(*) FILTER (WHERE fv.valor_tipo = 'NK')      AS valores_nk,
    MAX(fv.cargado_en) AS ultima_carga
FROM inventario.fact_valores_etf     fv
JOIN inventario.dim_versiones        dv ON dv.version_id      = fv.version_id
JOIN inventario.dim_anhos            di ON di.anho_id         = fv.anho_id
JOIN inventario.dim_variables_etf    ve ON ve.variable_etf_id = fv.variable_etf_id
GROUP BY dv.nombre_version, ve.sector;

-- ============================================================
-- DATOS INICIALES
-- ============================================================

INSERT INTO inventario.dim_versiones (nombre_version, anho_base_desde, anho_base_hasta, activa, descripcion) VALUES
('3IBA', 1990, 2017, FALSE, 'Tercer Informe Bienal de Actualización'),
('4CN',  1990, 2019, FALSE, 'Cuarta Comunicación Nacional'),
('1BTR', 1990, 2021, TRUE,  'Primer Informe Bienal de Transparencia – en procesamiento actual'),
('2BTR', 1990, 2024, FALSE, 'Segundo Informe Bienal de Transparencia – pendiente, JSON aún no disponibles');

-- ============================================================
-- PERMISOS (ajustar según usuarios del servidor DNCC)
-- ============================================================

-- Usuario de lectura para consultas e informes
-- CREATE ROLE ingei_readonly;
-- GRANT USAGE ON SCHEMA inventario, etf_output TO ingei_readonly;
-- GRANT SELECT ON ALL TABLES IN SCHEMA inventario TO ingei_readonly;
-- GRANT SELECT ON ALL TABLES IN SCHEMA etf_output TO ingei_readonly;

-- Usuario de pipeline (Python ETL)
-- CREATE ROLE ingei_etl;
-- GRANT USAGE ON SCHEMA staging, inventario, etf_output, auditoria TO ingei_etl;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA staging TO ingei_etl;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA inventario TO ingei_etl;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA etf_output TO ingei_etl;
-- GRANT INSERT ON auditoria.log_pipeline TO ingei_etl;
-- GRANT USAGE ON ALL SEQUENCES IN SCHEMA inventario TO ingei_etl;
-- GRANT USAGE ON ALL SEQUENCES IN SCHEMA etf_output TO ingei_etl;
