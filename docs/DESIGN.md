# Decisões aprovadas de apresentação

## Escopo

Somente Presidência da República, segundo turno. Direção visual **Observatório**, com tipografia sem serifa, superfícies discretas, linhas finas e predominância do número que representa a votação final projetada.

## Hierarquia

1. Votação final projetada de A e faixa de incerteza, com referência de 50%.
2. Gráfico: A em vermelho e B em azul; apurado contínuo, ligação à projeção tracejada, intervalo final visível.
3. Bloco “Apurado até agora”, depois do gráfico.
4. Detalhes sobre chance de vitória, hipóteses e incerteza.
5. Identificação: “Projeto do PET de Ciências Sociais da USP”.

O resumo numérico permanece centrado em A; B é seu complemento entre os válidos e aparece no gráfico. A curva de densidade normal e a grade de cem cenários foram retiradas a pedido do usuário.

“Agora” acompanha a linha vertical tracejada com oito pixels de afastamento. O rótulo passa para o outro lado perto da borda. As cores identificam as candidaturas, acompanhadas por nomes e rótulos numéricos.

## Adaptação para a aplicação

A aplicação preserva o desenho aprovado e acrescenta estados de carregamento, espera, ausência de previsão, falha e desatualização. Os dados reais e a demonstração são entradas separadas. O controle de momentos fica disponível apenas na demonstração; o modo real recebe atualizações pelo endpoint.

O intervalo é rotulado com o nível informado pelo modelo. O eixo da faixa mantém pelo menos 40% a 60%, expandindo quando necessário para mostrar todos os valores; não dá zoom a cada redução da incerteza. O resultado observado prevalece ao concluir a apuração.

O mockup aprovado está preservado em `mockup/`. O benchmark em `docs/benchmark/` registra uma etapa anterior e inclui eleições parlamentaristas como referências estéticas. Sugestões antigas sobre primeiro turno, governadores ou cadeiras não ampliam o escopo aprovado.
