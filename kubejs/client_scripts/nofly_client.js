// ============================================================================
// CLIENT SCRIPT: Bloqueio Local de Elytra e Voo na Vila (nofly_client.js)
// Plataforma: NeoForge 1.21.1 | Motor: KubeJS 6+ / 7+ (Client-Side)
// ============================================================================

(function (globalScope) {
    const $Minecraft = Java.loadClass('net.minecraft.client.Minecraft');
    const Vec3 = Java.loadClass('net.minecraft.world.phys.Vec3');

    // Estado local sincronizado pelo servidor via pacotes de rede
    const estadoLocal = {
        ativo: false,
        dimensao: 'minecraft:overworld',
        minX: -150,
        maxX: 150,
        minY: 50,
        maxY: 320,
        minZ: -150,
        maxZ: 150
    };

    /**
     * Escuta os pacotes de coordenadas e status da vila enviados pelo servidor.
     */
    NetworkEvents.dataReceived('vila_nofly_sync', event => {
        let data = event.data;
        if (!data) return;

        if (typeof data.ativo === 'boolean') {
            estadoLocal.ativo = data.ativo;
        }

        if (typeof data.minX === 'number') {
            estadoLocal.minX = data.minX;
            estadoLocal.maxX = data.maxX;
            estadoLocal.minY = data.minY;
            estadoLocal.maxY = data.maxY;
            estadoLocal.minZ = data.minZ;
            estadoLocal.maxZ = data.maxZ;
            estadoLocal.dimensao = data.dim || 'minecraft:overworld';
        }
    });

    /**
     * Escuta atualizações e streaming de configurações do servidor em direto.
     */
    NetworkEvents.dataReceived('kjs_stream_client_script', event => {
        let data = event.data;
        if (!data) return;
        if (data.limites) {
            Object.assign(estadoLocal, data.limites);
        }
    });

    /**
     * Interceção de frame no cliente local: Cancela o início do voo de Elytra
     * ANTES de a câmara inclinar, de abrir as asas ou tocar som de vento.
     */
    ClientEvents.tick(event => {
        let mc = $Minecraft.getInstance();
        let player = mc.player;
        if (!player || player.isCreative() || player.isSpectator()) return;

        // 1. Verificação local autônoma por coordenadas (redundância de zero latência)
        let nivel = player.level;
        let dimAtual = nivel ? String(nivel.dimension) : '';
        let px = player.x;
        let py = player.y;
        let pz = player.z;

        let dentroDaVila = (
            dimAtual === estadoLocal.dimensao &&
            px >= estadoLocal.minX && px <= estadoLocal.maxX &&
            py >= estadoLocal.minY && py <= estadoLocal.maxY &&
            pz >= estadoLocal.minZ && pz <= estadoLocal.maxZ
        );

        let aplicarRestricao = estadoLocal.ativo || dentroDaVila;
        if (!aplicarRestricao) return;

        // 2. Deteção e cancelamento imediato de Elytra no cliente
        if (player.isFallFlying()) {
            if (typeof player.stopFallFlying === 'function') {
                player.stopFallFlying();
            }
            player.setSharedFlag(7, false);
        }

        // 3. Cap suave local de velocidade a 150% (Sem Slowness, Sem Zoom/Wobble de FOV!)
        let vel = player.getDeltaMovement();
        let vx = vel.x();
        let vz = vel.z();
        let hSpeedSq = vx * vx + vz * vz;
        let maxClientH = 0.29; // Calibrado exatamente para 150% do sprint base vanilla (~0.28-0.29 blocos/tick)
        if (hSpeedSq > (maxClientH * maxClientH)) {
            let scale = maxClientH / Math.sqrt(hSpeedSq);
            player.setDeltaMovement(new Vec3(vx * scale, vel.y(), vz * scale));
        }

        // 4. Suporte ao mod KubeJS Additions (se instalado no cliente)
        try {
            if (typeof player.elytra === 'function') {
                player.elytra(false);
            }
        } catch (e) {}
    });

})(this);
