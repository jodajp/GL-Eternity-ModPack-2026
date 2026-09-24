$repo = "jodajp/GL-Eternity-ModPack-2026"
$tag = "latest"
$modsFolder = Join-Path $PSScriptRoot "mods"
$outputIndex = Join-Path $PSScriptRoot "automodpack-index.json"

Write-Host "A calcular hashes dos mods..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $modsFolder)) {
    Write-Error "Pasta de mods nao encontrada: $modsFolder"
    return
}

$filesList = [System.Collections.Generic.List[PSCustomObject]]::new()
$sha256Managed = [System.Security.Cryptography.SHA256]::Create()

$jarFiles = Get-ChildItem -LiteralPath $modsFolder -Filter *.jar

foreach ($file in $jarFiles) {
    try {
        $fileStream = [System.IO.File]::OpenRead($file.FullName)
        $hashBytes = $sha256Managed.ComputeHash($fileStream)
        $fileStream.Close()
        $fileStream.Dispose()

        $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()

        $filesList.Add([PSCustomObject]@{
            path = $file.Name
            hash = $hashString
            size = $file.Length
        })
    } catch {
        Write-Warning "Falha ao ler ${file}: $_"
    }
}
$sha256Managed.Dispose()

$manifest = [PSCustomObject]@{
    version = 1
    files = $filesList
}

# Salvar o manifesto JSON
$jsonContent = $manifest | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($outputIndex, $jsonContent, [System.Text.Encoding]::UTF8)

Write-Host "Hashes concluidos ($($filesList.Count) mods). A preparar GitHub Release..." -ForegroundColor Cyan

# Garantir que a release existe
gh release view $tag --repo $repo 2>$null
if ($LASTEXITCODE -ne 0) {
    gh release create $tag --title "Latest Build" --notes "Build sincronizada automaticamente" --repo $repo
}

# 1. Upload do manifesto JSON primeiro
Write-Host "A enviar manifesto JSON..." -ForegroundColor Yellow
gh release upload $tag $outputIndex --repo $repo --clobber

# 2. Upload iterativo dos mods (resolve o problema dos colchetes [])
Write-Host "A enviar ficheiros JAR para a Release..." -ForegroundColor Yellow
$total = $jarFiles.Count
$current = 0

# Mudamos o contexto para a pasta mods para evitar caminhos absolutos longos e problemas de globbing
Push-Location -LiteralPath $modsFolder

try {
    foreach ($file in $jarFiles) {
        $current++
        Write-Host "[$current/$total] Upload: $($file.Name)" -ForegroundColor Gray
        
        # O truque aqui e passar o nome relativo entre aspas para o gh
        gh release upload $tag "$($file.Name)" --repo $repo --clobber 2>$null
        
        if ($LASTEXITCODE -ne 0) {
            # Se falhar pelo nome com colchetes, tenta passando via pipeline/standard input
            Write-Warning "Tentativa direta falhou para $($file.Name). A reprocessar..."
            gh release upload $tag "./$($file.Name)" --repo $repo --clobber
        }
    }
} finally {
    Pop-Location
}

Write-Host "`nSucesso total! A versao 'latest' tem todos os mods e manifesto carregados." -ForegroundColor Green