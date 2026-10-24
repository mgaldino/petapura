# Entrada de terminal para conferir a publicação dos dados, sem análises.
args_all <- commandArgs(FALSE)
root <- dirname(normalizePath(sub("^--file=", "", args_all[grepl("^--file=", args_all)])[1]))
source(file.path(root, "ler_dados_tse.R"), encoding = "UTF-8")
args <- commandArgs(TRUE)
directory <- if (length(args)) args[1] else file.path(root, "data", "live", "tse_export")
d <- ler_dados_tse(directory)
cat("Snapshot:", d$manifesto$snapshot_id, "\n",
    "Publicado UTC:", d$manifesto$published_utc, "\n",
    "Modo:", d$manifesto$mode, "\n",
    "Seções no inventário:", nrow(d$inventario), "\n",
    "Seções com BU observado:", nrow(d$secoes), "\n",
    "Fontes de totalização disponíveis:", nrow(d$fontes), "\n",
    "Fonte escolhida:", d$manifesto$official_source_selected, "\n", sep = " ")
stopifnot(nrow(d$inventario) == d$manifesto$inventory_sections,
          nrow(d$secoes) == d$manifesto$observed_sections)
