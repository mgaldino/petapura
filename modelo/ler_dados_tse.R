# Consome um snapshot de dados observados. Nenhum modelo é estimado ou chamado.
ler_dados_tse <- function(diretorio, tentativas = 3L) {
  stopifnot(tentativas >= 1L)
  required <- c("jsonlite", "digest", "data.table")
  missing <- required[!vapply(required, requireNamespace, TRUE, quietly = TRUE)]
  if (length(missing)) stop("Instale os pacotes: ", paste(missing, collapse = ", "))
  directory <- normalizePath(diretorio, mustWork = TRUE)
  pointer <- file.path(directory, "manifest.json")
  read_raw <- function(path) {
    connection <- file(path, "rb"); on.exit(base::close(connection))
    readBin(connection, "raw", n = file.info(path)$size)
  }
  last_error <- NULL
  for (attempt in seq_len(tentativas)) {
    result <- tryCatch({
      manifest <- jsonlite::fromJSON(rawToChar(read_raw(pointer)), simplifyVector = FALSE)
      stopifnot(manifest$schema_version == 1, manifest$mode == "observed_data_only")
      content <- list()
      for (name in names(manifest$files)) {
        entry <- manifest$files[[name]]
        path <- normalizePath(file.path(directory, entry$path), mustWork = TRUE)
        if (!startsWith(path, paste0(directory, "/"))) stop("Caminho fora do snapshot")
        raw <- read_raw(path)
        if (!identical(digest::digest(raw, algo = "sha256", serialize = FALSE), entry$sha256))
          stop("Arquivo mudou durante leitura ou perdeu integridade: ", name)
        content[[name]] <- if (entry$kind == "csv")
          data.table::fread(text = rawToChar(raw), encoding = "UTF-8") else
          jsonlite::fromJSON(rawToChar(raw), simplifyVector = FALSE)
      }
      current <- jsonlite::fromJSON(rawToChar(read_raw(pointer)), simplifyVector = FALSE)
      if (!identical(current$snapshot_id, manifest$snapshot_id)) stop("Novo snapshot publicado durante leitura")
      list(manifesto = manifest, secoes = content[["observed.csv"]],
        inventario = content[["inventory.csv"]], fontes = content[["official_sources.csv"]],
        totalizacao_selecionada = content[["official_selected.csv"]],
        detalhes_fontes = content[["official_selected.json"]], status = content[["status.json"]])
    }, error = function(error) {last_error <<- error; NULL})
    if (!is.null(result)) return(result)
    if (attempt < tentativas) Sys.sleep(.25 * attempt)
  }
  stop("Não foi possível ler snapshot consistente: ", conditionMessage(last_error))
}
