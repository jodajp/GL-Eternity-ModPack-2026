# 1. Configurações
$repo = "jodajp/GL-Eternity-ModPack-2026" 
$tag = "latest"
$modsFolder = Join-Path $PSScriptRoot "mods"
$outputIndex = Join-Path $PSScriptRoot "automodpack-index.json"

Write-Host "A calcular hashes dos mods..." -ForegroundColor Cyan

# 2. Gerar manifesto JSON (compativel com AutoModpack)
$filesList = [System.Collections.Generic.List[PSCustomObject]]::new()
$sha256Managed = [System.Security.Cryptography.SHA256]::Create()

$jarFiles = Get-ChildItem -LiteralPath $modsFolder -Filter *.jar

foreach ($file in $jarFiles) {
    $fileStream = [System.IO.File]::OpenRead($file.FullName)
    $hashBytes = $sha256Managed.ComputeHash($fileStream)
    $fileStream.Close()
    $fileStream.Dispose()

    $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()

    # O AutoModpack em Releases normalmente espera o nome direto do ficheiro se a URL for plana
    $filesList.Add([PSCustomObject]@{
        path = $file.Name
        hash = $hashString
        size = $file.Length
    })
}
$sha256Managed.Dispose()

$manifest = [PSCustomObject]@{
    version = 1
    files = $filesList
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outputIndex -Encoding UTF8

Write-Host "Hashes concluidos. A sincronizar com o GitHub Releases..." -ForegroundColor Cyan

# 3. Criar a release 'latest' se nao existir, ou atualizar se ja existir
# Garante que a release existe sem falhar
gh release view $tag --repo $repo 2>$null
if ($LASTEXITCODE -ne 0) {
    gh release create $tag --title "Latest Build" --notes "Atualizacao automatica do modpack" --repo $repo
}

# 4. Upload em lote dos ficheiros JAR (sobrescrevendo alterados com --clobber)
Write-Host "A enviar os ficheiros binarios para a Release (isto pode demorar consoante o upload)..." -ForegroundColor Yellow
$jarPaths = $jarFiles | ForEach-Object { $_.FullName }

# Envia o ficheiro de indice e todos os mods em paralelo/lote
gh release upload $tag $outputIndex $jarPaths --repo $repo --clobber

Write-Host "Sucesso total! A versao 'latest' esta atualizada no GitHub Releases." -ForegroundColor Green