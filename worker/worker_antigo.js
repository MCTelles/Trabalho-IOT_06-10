// ================================================================
//  WORKER ANTIGO (INSEGURO) - SO PARA O PRINT DO PASSO 1
//  Igual ao da atividade de D1: grava QUALQUER coisa que chega no /insert.
//  Sem API key, sem assinatura, sem validacao de faixa.
//  Depois do print, volte a publicar o worker.js novo!
// ================================================================
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/insert" && request.method === "POST") {
      const b = await request.json();                 // confia em tudo
      await env.DB.prepare("INSERT INTO leituras (sensor, valor, timestamp) VALUES (?, ?, ?)")
        .bind(String(b.sensor), Number(b.valor), Date.now()).run();
      return new Response(`OK: ${b.sensor}=${b.valor}`);
    }

    if (url.pathname === "/list") {
      const sensor = url.searchParams.get("sensor") || "temp";
      const { results } = await env.DB.prepare(
        "SELECT valor, timestamp FROM leituras WHERE sensor = ? ORDER BY timestamp DESC LIMIT 50"
      ).bind(sensor).all();
      return Response.json(results);
    }

    if (url.pathname === "/resumo") {
      const { results } = await env.DB.prepare(
        "SELECT sensor, AVG(valor) AS media, MAX(valor) AS maximo, COUNT(*) AS n FROM leituras GROUP BY sensor"
      ).all();
      return Response.json(results);
    }

    return new Response("Rotas: POST /insert | GET /list?sensor=temp | GET /resumo", { status: 404 });
  }
};
