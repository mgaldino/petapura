from pathlib import Path
import json, shutil, html
from reportlab.pdfgen import canvas
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph, Table, TableStyle
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader

BASE = Path(__file__).resolve().parent
OUT = BASE / 'output' / 'pdf'
OUT.mkdir(parents=True, exist_ok=True)
FONT = Path('/System/Library/Fonts/Supplemental')
pdfmetrics.registerFont(TTFont('Arial', str(FONT/'Arial.ttf')))
pdfmetrics.registerFont(TTFont('ArialBold', str(FONT/'Arial Bold.ttf')))
pdfmetrics.registerFontFamily('Arial', normal='Arial', bold='ArialBold')
W,H = A4
INK = colors.HexColor('#13283b')
MUTED = colors.HexColor('#526575')
ACCENT = colors.HexColor('#086d82')
STYLE = ParagraphStyle('body',fontName='Arial',fontSize=10.3,leading=15,textColor=INK,spaceAfter=9)
SMALL = ParagraphStyle('small',parent=STYLE,fontSize=8.2,leading=11.5,textColor=MUTED)
UNCERTAINTY_SOURCE = 'https://analysisfunction.civilservice.gov.uk/policy-store/communicating-quality-uncertainty-and-change/'
UNCERTAINTY_PRINCIPLE = 'A incerteza deve ser visível na primeira tela, junto da previsão. A pessoa deve conseguir reconhecer quais resultados ainda são plausíveis, quanto a previsão pode variar e o que o modelo considera ao calcular essa faixa.'
UNCERTAINTY_REVIEW = [
    ('Projeção 2026, exemplo brasileiro', 'Faixa numérica de 90% junto à estimativa.', 'Comunicação explícita, mas a captura é do fim da apuração. Avaliar a legibilidade quando a faixa for ampla.'),
    ('Agulha 2026, exemplo brasileiro', 'Probabilidade de um evento: vitória no primeiro turno.', 'Na primeira tela capturada, a incerteza da votação final não aparece como intervalo.'),
    ('NYT', 'Referência de probabilidade de vitória.', 'Sem acesso direto: não foi possível verificar aqui a apresentação completa da incerteza.'),
    ('ABC', 'Estados da disputa: incerta, provável e eleita.', 'Categorias ajudam a leitura; não dão a amplitude numérica da votação projetada.'),
    ('Demais capturas internacionais', 'Placares e comparações em páginas de resultados históricos.', 'Esses enquadramentos não permitem avaliar como a incerteza foi apresentada durante a apuração.'),
]

ITEMS = [
 dict(id='nyt', name='New York Times - The Needle', country='Estados Unidos', year='2024',
      url='https://www.nytimes.com/interactive/2024/11/05/us/elections/results-president-forecast-needle.html',
      kind='Projeção probabilística', images=[],
      observation='A agulha sintetiza a probabilidade de vitória durante a apuração. É a referência conceitual para um indicador nacional de tendência.',
      takeaway='Usar uma pergunta explícita para cada indicador: chance de vencer, chance de vitória no primeiro turno ou chance de ir ao segundo turno. São eventos diferentes.',
      limit='Acesso direto bloqueado pelo ambiente. Sem captura própria ou auditoria visual da versão de 2024. O endereço foi identificado em referência pública; não houve teste de navegação no NYT.'),
 dict(id='abc', name='ABC News', country='Austrália', year='2025',
      url='https://www.abc.net.au/news/elections/federal/2025/results',
      kind='Placar, cartograma e estados da disputa', images=['03-abc-placar.png','04-abc-cartograma.png'],
      observation='Barras mostram cadeiras e o limiar de maioria. Um cartograma dá a mesma área aos distritos; a legenda distingue disputa incerta, provável e eleita. Há busca e filtros.',
      takeaway='Boa referência para a hierarquia da página e para cartões de governadores. No mapa presidencial brasileiro, o tamanho das marcas deve representar votos ou eleitores se a intenção for mostrar peso eleitoral.',
      limit='Cada distrito australiano elege uma cadeira. Dar a mesma área a municípios brasileiros mudaria o significado: municípios têm eleitorados muito diferentes.'),
 dict(id='guardian', name='The Guardian', country='Reino Unido', year='2024',
      url='https://www.theguardian.com/politics/ng-interactive/2024/jul/04/uk-general-election-results-2024-live-in-full',
      kind='Placar e comparação histórica', images=['05-guardian-placar.png'],
      observation='Placar por partido, saldo histórico e busca territorial.',
      takeaway='Para o Brasil, vale uma coluna opcional com a diferença em pontos percentuais em relação à eleição anterior, com comparação territorial consistente.',
      limit='Cadeiras e votos expressam medidas distintas. A adaptação brasileira deve rotular claramente a unidade exibida.'),
 dict(id='lemonde', name='Le Monde', country='França', year='2024',
      url='https://www.lemonde.fr/resultats-legislatives-2024/',
      kind='Composição parlamentar e busca local', images=['06-lemonde-hemiciclo.png'],
      observation='O hemiciclo dá uma visão da composição da Assembleia e marca a maioria necessária. A página oferece busca territorial e apresenta participação, votos brancos e nulos.',
      takeaway='Útil para uma eventual cobertura legislativa. Na Presidência, aproveitar a hierarquia de informação e a navegação local; o hemiciclo teria pouca função.',
      limit='A imagem mostra cadeiras já atribuídas na página histórica; não é uma distribuição de probabilidades.'),
 dict(id='reuters', name='Reuters Graphics', country='Índia', year='2024',
      url='https://www.reuters.com/graphics/INDIA-ELECTION/zgponbzllvd/',
      kind='Comparação entre eleições e mapa', images=['07-reuters-comparacao.png','08-reuters-mapa.png'],
      observation='Barras alinhadas comparam as coalizões em 2024 e 2019. O mapa localiza os resultados por circunscrição. A apresentação combina gráficos com explicação editorial e fontes.',
      takeaway='Boa referência para explicar de onde vem uma mudança na projeção: visualização curta, seguida de uma frase que conecte a atualização aos dados recebidos.',
      limit='O mapa geográfico enfatiza áreas extensas. Para uma eleição presidencial, complementar com votos, eleitorado ou contribuição para a diferença nacional.'),
 dict(id='lanacion', name='La Nación', country='Argentina', year='2023',
      url='https://www.lanacion.com.ar/politica/elecciones-2023-los-resultados-del-balotaje-entre-sergio-massa-y-javier-milei-en-todo-el-pais-nid20112023/',
      kind='Duelo presidencial e margem', images=['09-lanacion-placar.png'],
      observation='O placar do segundo turno põe os dois candidatos na mesma barra, explicita a diferença e permite escolher território. Há uma visualização dedicada à diferença entre candidatos.',
      takeaway='Uma das referências mais diretamente transferíveis ao segundo turno brasileiro: comparação lado a lado, marco de 50% e diferença em pontos percentuais.',
      limit='É necessário acrescentar a faixa de incerteza da nossa projeção. Uma barra com votação apurada não comunica sozinha a probabilidade de vitória.'),
 dict(id='zeit', name='DIE ZEIT', country='Alemanha', year='2025',
      url='https://www.zeit.de/politik/deutschland/2025-02/bundestagswahl-2025-wahlergebnisse-wahlkreise-live',
      kind='Comparação histórica e cenários', images=['10-zeit-original.png','12-zeit-portugues.png'],
      observation='Barras comparam eleições; cenários de coalizão mostram o limiar de maioria.',
      takeaway='A comparação visual pode inspirar módulos brasileiros de evolução e cenários. Coalizões parlamentares exigem uma adaptação substantiva; não equivalem a probabilidades de candidatos.',
      limit='Original em alemão e adaptação para português por edição de imagem. Números e rótulos foram conferidos visualmente; a adaptação não é uma captura do site em português.'),
 dict(id='elpais', name='El País', country='Espanha', year='2023',
      url='https://elpais.com/espana/elecciones/generales/',
      kind='Abas e comparação de composição', images=['11-elpais-escanos.png'],
      observation='Abas alternam cadeiras, resultados e mapa. Arcos concêntricos comparam a composição de 2023 e 2019. Há busca territorial, horário e percentual apurado.',
      takeaway='A navegação por abas é uma boa solução para celular. Podemos alternar resumo, evolução e mapa sem exigir que tudo caiba na primeira tela.',
      limit='Arcos e cadeiras atendem a uma eleição parlamentar; para a Presidência, barras horizontais favorecem a comparação direta dos candidatos.'),
]

def paragraph(c,text,x,y,width,style=STYLE):
    p=Paragraph(text,style); _,height=p.wrap(width,1000); p.drawOn(c,x,y-height); return y-height-style.spaceAfter

def header(c,title,kicker='BENCHMARK VISUAL | APURAÇÃO ELEITORAL',page=1):
    c.setFillColor(ACCENT);c.rect(0,H-13,W,13,fill=1,stroke=0)
    paragraph(c,kicker,38,H-33,W-76,SMALL)
    title_style=ParagraphStyle('title',parent=STYLE,fontName='ArialBold',fontSize=23,leading=28)
    y=paragraph(c,title,38,H-64,W-76,title_style)-4
    c.setStrokeColor(colors.HexColor('#dce4e9'));c.line(38,38,W-38,38)
    c.setFont('Arial',8);c.setFillColor(MUTED)
    c.drawString(38,24,'Consulta e capturas: 20/10/2026 | referência de apresentação')
    c.drawRightString(W-38,24,str(page))
    return y

def imagefit(c,path,x,y,width,maxheight):
    im=ImageReader(str(path));iw,ih=im.getSize();scale=min(width/iw,maxheight/ih)
    dw,dh=iw*scale,ih*scale
    c.drawImage(im,x+(width-dw)/2,y-dh,width=dw,height=dh,mask='auto')
    c.setStrokeColor(colors.HexColor('#cfd9e0'));c.rect(x+(width-dw)/2,y-dh,dw,dh,stroke=1,fill=0)
    return dh

def link(c,label,url,x,y,width):
    return paragraph(c,f'<link href="{html.escape(url,quote=True)}" color="#086d82"><u>{html.escape(label)}</u></link>',x,y,width,SMALL)

def uncertainty_pages(c):
    y=header(c,'A incerteza é parte da previsão','REQUISITO CENTRAL DO PROJETO | DEFINIDO EM 20/10/2026',2)
    y=paragraph(c,UNCERTAINTY_PRINCIPLE,38,y,W-76)
    sections=[
      ('Votação final e resultados plausíveis','Mostrar a estimativa junto de uma faixa preditiva, com nível e significado definidos pela metodologia. No resumo, uma faixa bem explicada pode bastar; nos detalhes, intervalos aninhados ou a distribuição completa. A faixa representa a incerteza do resultado final, conforme os componentes incluídos no modelo.'),
      ('Probabilidade de vitória e possibilidade de derrota','Exibir a probabilidade complementar com a mesma clareza: por exemplo, 80% de chance de vitória de A e 20% de B, em um segundo turno com esses dois desfechos. Explicar que um resultado menos provável continua possível. Probabilidade de vitória e percentual de votos medem coisas distintas.'),
      ('Diferença entre candidatos','No segundo turno, considerar a distribuição da diferença A menos B, em pontos percentuais, com zero marcado. Ela permite ver os cenários de vitória de cada lado. Calcular a diferença a partir da distribuição conjunta; a sobreposição de intervalos individuais não determina a chance de vitória.'),
      ('Evolução ao longo da apuração','Preservar o histórico da estimativa e de sua faixa. Permitir que novas informações movam ou ampliem a incerteza quando o modelo indicar. O desenho não deve impor um estreitamento automático com o avanço da contagem.'),
      ('Por que ainda existe incerteza','Relacionar a previsão aos votos ainda esperados e à composição territorial do que falta entrar, quando houver suporte no modelo. Percentual apurado não é uma medida suficiente de precisão. Explicar quais fontes de incerteza entram na faixa e quais ficam fora dela.'),
    ]
    for title,body in sections:
        y=paragraph(c,'<b>'+title+'</b>',38,y,W-76)
        y=paragraph(c,body,38,y,W-76)
    y=paragraph(c,'<b>Critério de compreensão:</b> testar se o leitor identifica quem é favorito, reconhece que o outro ainda pode ganhar e distingue chance de vitória de participação nos votos. Antes da apuração real, validar intervalos e probabilidades em replays históricos; uma interface clara depende de quantidades estatísticas adequadas.',38,y,W-76,SMALL)
    link(c,'Referência de comunicação: Government Analysis Function / Data Quality Hub',UNCERTAINTY_SOURCE,38,y,W-76)
    c.showPage()
    y=header(c,'Releitura do benchmark: incerteza','O QUE FOI OBSERVADO | LIMITES DAS CAPTURAS',3)
    y=paragraph(c,'As interfaces são úteis como repertório visual, mas o projeto deve ser avaliado também pela compreensão da incerteza. As capturas disponíveis não sustentam uma conclusão geral de que esses veículos omitiram incerteza durante a noite eleitoral.',38,y,W-76)
    data=[['Referência','Comunicação observada','Implicação para a avaliação']]+UNCERTAINTY_REVIEW
    cells=[[Paragraph(html.escape(t),SMALL) for t in row] for row in data]
    t=Table(cells,colWidths=[123,163,W-76-286],hAlign='LEFT')
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#e8f2f4')),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),10),('BOTTOMPADDING',(0,0),(-1,-1),10),('LINEBELOW',(0,0),(-1,-1),0.4,colors.HexColor('#dce4e9'))]))
    _,th=t.wrap(W-76,H);t.drawOn(c,38,y-th);y-=th+17
    y=paragraph(c,'<b>Consequência para a escolha visual.</b> O placar do La Nación continua útil para comparar os candidatos. A distribuição da previsão e sua faixa passam a ter presença central. A agulha pode resumir um evento, acompanhada de informação que torne o resultado alternativo visível.',38,y,W-76)
    y=paragraph(c,'<b>Ligação com a sessão de modelagem.</b> Planejar a interface para receber distribuições ou simulações conjuntas, quantis, probabilidades dos eventos relevantes e histórico por atualização. Registrar também cobertura da apuração e diagnósticos disponíveis. Exibir somente quantidades sustentadas pelo modelo; este benchmark não altera o modelo da outra sessão.',38,y,W-76)
    c.showPage()

def build():
    path=OUT/'benchmark_apuracao_eleitoral_2026.pdf'
    c=canvas.Canvas(str(path),pagesize=A4)
    c.setTitle('Benchmark visual de apuração eleitoral - Brasil 2026')
    c.setAuthor('Pesquisa preparada para Manoel Galdino')
    y=header(c,'Referências para a noite eleitoral de 2026',page=1)
    y=paragraph(c,'<b>Prioridade do projeto:</b> comunicar a incerteza das previsões. A primeira tela deve combinar placar, distribuição ou faixa da votação final e probabilidade dos desfechos. A agulha é uma síntese possível, com os resultados alternativos claramente visíveis.',38,y,W-76)
    y=paragraph(c,'Escopo: oito referências internacionais, de oito países e quatro continentes, além dos dois exemplos brasileiros enviados. O foco é apresentação. Não houve avaliação estatística dos modelos, teste de carga ou validação da atualização em tempo real.',38,y,W-76)
    data=[['Referência','Eleição','Principal contribuição visual']]
    for d in ITEMS:
        data.append([d['name'],d['country']+' / '+d['year'],d['kind']])
    cells=[[Paragraph(html.escape(t),SMALL) for t in row] for row in data]
    t=Table(cells,colWidths=[138,119,W-76-257],hAlign='LEFT')
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#e8f2f4')),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8),('LINEBELOW',(0,0),(-1,-1),0.4,colors.HexColor('#dce4e9'))]))
    _,th=t.wrap(W-76,H);t.drawOn(c,38,y-th);y-=th+17
    y=paragraph(c,'<b>Como ler as capturas:</b> são enquadramentos reais em janela compacta de navegador, úteis para avaliar a leitura no celular. As páginas internacionais mostram hoje os resultados históricos; as imagens não reconstituem a sequência original da noite eleitoral.',38,y,W-76,SMALL)
    y=paragraph(c,'<b>Disponibilidade:</b> sete referências internacionais têm captura própria. O NYT entra como referência conceitual com link e limitação de acesso. A captura alemã acompanha uma versão traduzida identificada.',38,y,W-76,SMALL)
    c.showPage()
    uncertainty_pages(c)
    page=4;fig=1
    for d in ITEMS:
        if not d['images']:continue
        y=header(c,d['name'],f"{d['country'].upper()} | ELEIÇÃO DE {d['year']}",page)
        y=paragraph(c,'<b>O que observar.</b> '+d['observation'],38,y,W-76)
        y=paragraph(c,'<b>Aplicação ao Brasil.</b> '+d['takeaway'],38,y,W-76)
        available=y-169
        if len(d['images'])==1:
            height=imagefit(c,BASE/d['images'][0],38,y,W-76,min(available,430))
        else:
            width=(W-92)/2
            if d['id']=='zeit':
                paragraph(c,'Original em alemão',38,y,width,SMALL)
                paragraph(c,'Adaptação em português',54+width,y,width,SMALL)
                y-=19
            height=max(imagefit(c,BASE/d['images'][0],38,y,width,min(available,390)),imagefit(c,BASE/d['images'][1],54+width,y,width,min(available,390)))
        y-=height+15
        y=paragraph(c,f'<b>Figura {fig}.</b> Captura'+('s' if len(d['images'])>1 else '')+f" da interface de {d['name']}, consultada em 20/10/2026.",38,y,W-76,SMALL)
        y=paragraph(c,'<b>Leitura e limites.</b> '+d['limit'],38,y,W-76,SMALL)
        link(c,'Abrir a referência original',d['url'],38,y,W-76)
        c.showPage();page+=1;fig+=1
    y=header(c,'Os dois exemplos brasileiros enviados','BRASIL | REFERÊNCIAS DO PEDIDO',page)
    y=paragraph(c,'<b>Projeção 2026:</b> destaca estimativa final, faixa de 90% e resultado apurado em cartões simples. <b>Agulha 2026:</b> combina barras, indicador de primeiro turno e cartões por estado. As imagens registram apenas o estado exibido pelos sites na consulta; não validam os números nem os modelos.',38,y,W-76)
    width=(W-92)/2
    paragraph(c,'Projeção 2026',38,y,width,SMALL);paragraph(c,'Agulha 2026',54+width,y,width,SMALL);y-=19
    hh=max(imagefit(c,BASE/'01-projecao-brasil.png',38,y,width,330),imagefit(c,BASE/'02-agulha-brasil.png',54+width,y,width,330));y-=hh+15
    y=paragraph(c,f'<b>Figura {fig}.</b> As duas interfaces fornecidas pelo usuário, capturadas em 20/10/2026.',38,y,W-76,SMALL)
    y=paragraph(c,'Para o nosso site, eu manteria a distinção visível entre apurado e projetado, acrescentaria a evolução com intervalo e daria ao indicador uma pergunta precisa. Em primeiro turno, a probabilidade de passar ao segundo turno e a de ganhar já no primeiro exigem rótulos próprios.',38,y,W-76)
    y=link(c,'Abrir Projeção 2026','https://projecao.2026elections.workers.dev',38,y,W-76)
    link(c,'Abrir Agulha 2026','https://agulha2026.pages.dev',38,y,W-76)
    c.showPage();page+=1
    y=header(c,'O que eu levaria para o nosso site','SÍNTESE DE DESIGN | PROPOSTA PARA DISCUSSÃO',page)
    recs=[
      ('1. Resumo nacional na primeira tela','Candidatos, votação apurada, percentual de seções totalizadas, horário e fonte. Em bloco separado e igualmente legível: projeção final e intervalo. Percentual de seções e percentual estimado de votos apurados precisam de rótulos e denominadores próprios.'),
      ('2. Uma pergunta explícita para a agulha','No segundo turno: chance de vitória de cada candidato. No primeiro: chance de vencer sem segundo turno e chance de classificação, se o modelo fornecer essas quantidades. Evitar um único medidor que tente responder a todas as perguntas.'),
      ('3. Evolução com incerteza','Uma linha mostra a projeção ao longo da noite e uma faixa mostra a incerteza do modelo. Uma segunda série pode mostrar a votação já apurada, com legenda inequívoca. Explicar o nível e o significado do intervalo conforme a metodologia adotada.'),
      ('4. O que ainda falta entrar','Mapa ou lista por UF com cobertura da apuração. Se o modelo permitir, mostrar o peso dos votos ainda esperados e quais territórios mais influenciam a projeção. Uma lista ordenável deve funcionar sem depender de passar o mouse sobre um mapa.'),
      ('5. Estados e disputas acompanháveis','Busca de UF, cartões compactos de governadores e abertura dos detalhes. Diferenciar liderança na contagem, favoritismo do modelo, eventual anúncio editorial e resultado oficial, de acordo com as fontes e decisões do projeto.'),
      ('6. Uma interface calma e legível','Abas de resumo, evolução e mapa no celular; informação essencial no topo; cores acompanhadas de nomes ou símbolos; opção de reduzir movimento. Mostrar atraso ou interrupção dos dados com horário da última atualização efetiva.'),
    ]
    for title,body in recs:
        y=paragraph(c,'<b>'+title+'</b>',38,y,W-76)
        y=paragraph(c,body,38,y,W-76)
    c.showPage();page+=1
    y=header(c,'Links e limites da pesquisa','FONTES | TRILHA DE CONSULTA',page)
    for d in ITEMS:
        y=link(c,d['name']+' | '+d['country']+' | '+d['year'],d['url'],38,y,W-76)
    y=link(c,'Government Analysis Function / Data Quality Hub - comunicar incerteza',UNCERTAINTY_SOURCE,38,y,W-76)
    y-=8
    y=paragraph(c,'<b>NYT.</b> '+ITEMS[0]['observation']+' '+ITEMS[0]['takeaway']+' '+ITEMS[0]['limit'],38,y,W-76,SMALL)
    y=link(c,'Contexto sobre a agulha em 2024: Associated Press','https://apnews.com/article/87900329cb4a3400c021bde149011ef5',38,y,W-76)
    y=paragraph(c,'<b>Método.</b> Pesquisa na web, consulta das páginas originais acessíveis e inspeção visual em navegador. As capturas foram preservadas sem redesenho; a única edição visual é a versão em português do ZEIT, gerada com a ferramenta nativa de edição de imagem. A tradução altera rótulos e mantém os números conferidos no original. Não é uma réplica pixel a pixel.',38,y,W-76,SMALL)
    y=paragraph(c,'<b>Limites.</b> A seleção é intencional e voltada à discussão de interface. As recomendações são juízos de design desta pesquisa, sem estudo de usabilidade com usuários. Não foram medidos desempenho, acessibilidade completa, estabilidade de dados, qualidade estatística das projeções ou custo de manutenção. Links históricos podem mudar.',38,y,W-76,SMALL)
    c.save()
    (BASE/'referencias.json').write_text(json.dumps(ITEMS,ensure_ascii=False,indent=2),encoding='utf-8')
    (BASE/'criterios_incerteza.json').write_text(json.dumps({'date':'2026-10-20','principle':UNCERTAINTY_PRINCIPLE,'source':UNCERTAINTY_SOURCE,'review':UNCERTAINTY_REVIEW,'scope':'Avaliação de apresentação; o modelo em outra sessão não foi alterado.'},ensure_ascii=False,indent=2),encoding='utf-8')
    cards=[]
    for d in ITEMS:
        imgs=''.join(f'<figure><a href="{html.escape(fn)}"><img src="{html.escape(fn)}" alt="{html.escape(d["name"])} - '+('tradução em português' if 'portugues' in fn else 'captura original')+'"></a><figcaption>'+('Adaptação em português' if 'portugues' in fn else 'Captura original')+'</figcaption></figure>' for fn in d['images'])
        cards.append(f'<article><p class="kicker">{d["country"]} · {d["year"]}</p><h2>{html.escape(d["name"])}</h2><p>{html.escape(d["observation"])}</p><div class="images">{imgs}</div><p><b>Para nosso site:</b> {html.escape(d["takeaway"])}</p><p class="muted">{html.escape(d["limit"])}</p><a href="{html.escape(d["url"])}" target="_blank" rel="noopener">Abrir referência original ↗</a></article>')
    pagehtml='''<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Benchmark de apuração eleitoral</title><style>body{font:17px/1.55 system-ui;background:#eef3f5;color:#142b3d;margin:0}main{max-width:1120px;margin:auto;padding:32px 24px}h1{font-size:38px;line-height:1.15}h2{margin:0 0 12px}.kicker,.muted,figcaption{color:#526575}.kicker{font-size:13px;text-transform:uppercase;letter-spacing:.08em}article{background:white;border:1px solid #dce4e9;border-radius:14px;padding:28px;margin:24px 0}.images{display:flex;gap:20px;justify-content:center;align-items:flex-start;flex-wrap:wrap}figure{margin:8px 0;flex:1;min-width:220px;max-width:487px}img{width:100%;height:auto;border:1px solid #dce4e9;display:block}figcaption{font-size:13px;margin-top:6px}a{color:#00677c}header{border-bottom:3px solid #086d82;padding-bottom:22px}footer{font-size:14px;color:#526575}</style><main><header><p class="kicker">Pesquisa e capturas · 20/10/2026</p><h1>Como mostrar a noite eleitoral</h1><p>Oito referências internacionais de apresentação para o Brasil em 2026. Capturas em janela compacta, com links para exploração. A versão alemã acompanha tradução em português.</p><a href="output/pdf/benchmark_apuracao_eleitoral_2026.pdf">Abrir o relatório em PDF</a></header>'''+''.join(cards)+'''<footer><p>As imagens mostram as páginas consultadas em 20/10/2026. Os resultados internacionais são históricos. As recomendações são avaliações de design; não houve teste de carga, estudo de usabilidade ou validação dos modelos. A tradução do ZEIT é uma adaptação visual.</p></footer></main></html>'''
    uncertainty_html='<article><p class="kicker">Prioridade do projeto</p><h2>Comunicar a incerteza das previsões</h2><p>'+html.escape(UNCERTAINTY_PRINCIPLE)+'</p><ul><li>Faixa ou distribuição da votação final junto à estimativa.</li><li>Probabilidade de vitória e do resultado alternativo visíveis.</li><li>Evolução da estimativa e da faixa ao longo da noite.</li><li>Explicação sobre votos ainda esperados e limites do modelo.</li></ul><p>O relatório atualizado inclui uma releitura das referências sob esse critério. As capturas históricas não permitem concluir como cada veículo comunicou incerteza durante toda a apuração.</p></article>'
    pagehtml=pagehtml.replace('</header>','</header>'+uncertainty_html,1)
    (BASE/'galeria.html').write_text(pagehtml,encoding='utf-8')
    print(path)

if __name__=='__main__':build()
