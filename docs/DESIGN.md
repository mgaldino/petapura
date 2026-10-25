# Decisões aprovadas de apresentação

## Escopo

Somente Presidência da República, segundo turno. Direção visual **Observatório**, com tipografia sem serifa, superfícies discretas, linhas finas e predominância do número que representa a votação final projetada.

## Hierarquia

1. Votação final projetada de A e faixa de incerteza, com referência de 50%.
2. Gráfico: A em vermelho e B em azul; projeção do resultado final ao longo da apuração em linha contínua, a partir da previsão inicial, com a faixa de cada atualização; projeção atual tracejada depois de “Agora”; intervalo final visível na posição 100%, identificada como “Resultado final projetado”. O parcial apurado fica no quadro abaixo do gráfico e no tooltip (alteração de 25/10/2026).
3. Bloco “Apurado até agora”, depois do gráfico.
4. Detalhes sobre chance de vitória, hipóteses e incerteza.
5. Identificação: “Projeto do PET de Ciências Sociais da USP”.

O resumo numérico permanece centrado em A; B é seu complemento entre os válidos e aparece no gráfico. A curva de densidade normal e a grade de cem cenários foram retiradas a pedido do usuário.

O menu comum leva a três páginas: “Apuração” (`/`), “Sobre o modelo” (`/sobre-o-modelo/`) e “Quem somos” (`/quem-somos/`). A página atual fica sublinhada e identificada por `aria-current="page"`. Os textos institucionais e a explicação detalhada do modelo ficam nas páginas próprias, preservando a hierarquia da apuração na inicial. Essa separação foi solicitada em 23/10/2026.

“Agora” acompanha a linha vertical tracejada com oito pixels de afastamento. O rótulo passa para o outro lado perto da borda. As cores identificam as candidaturas, acompanhadas por nomes e rótulos numéricos.

## Adaptação para a aplicação

Em 24/10/2026, a abertura ganhou uma introdução que explica a projeção do resultado final a partir das urnas já apuradas. Enquanto não há seções totalizadas nem BUs incorporados, as caixas dos dois cenários permanecem visíveis com “ND” (não disponível) no percentual e na faixa. O gráfico mostra 50% para cada candidatura, identificado no título, na nota e na descrição acessível como referência visual de espera. Essa referência não usa os valores da prior, não possui faixa de incerteza nem tooltip de projeção. O parcial e os detalhes de incerteza ficam ocultos. O primeiro resultado totalizado ou BU incorporado libera automaticamente os valores dos cenários e o gráfico efetivo. Uma correção para zero restaura o estado de espera. A demonstração com dados fictícios mantém seu controle de momentos disponível.

A aplicação preserva o desenho aprovado e acrescenta estados de carregamento, espera, ausência de previsão, falha e desatualização. Os dados reais e a demonstração são entradas separadas. O controle de momentos fica disponível apenas na demonstração; o modo real recebe atualizações pelo endpoint.

O intervalo é rotulado com o nível informado pelo modelo. O eixo da faixa mantém pelo menos 40% a 60%, expandindo quando necessário para mostrar todos os valores; não dá zoom a cada redução da incerteza. O resultado observado prevalece ao concluir a apuração.

O mockup aprovado está preservado em `mockup/`. O benchmark em `docs/benchmark/` registra uma etapa anterior e inclui eleições parlamentaristas como referências estéticas. Sugestões antigas sobre primeiro turno, governadores ou cadeiras não ampliam o escopo aprovado.
