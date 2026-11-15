// Initiates the 3-member replica set rs0 (safe to run more than once).
// mongo1 gets a higher priority so it is the preferred primary after start-up.
try {
  const s = rs.status();
  print(`replica set already initiated: ${s.set}, members=${s.members.length}`);
} catch (e) {
  rs.initiate({
    _id: "rs0",
    members: [
      { _id: 0, host: "mongo1:27017", priority: 2 },
      { _id: 1, host: "mongo2:27017", priority: 1 },
      { _id: 2, host: "mongo3:27017", priority: 1 },
    ],
  });
  print("replica set rs0 initiated");
}
// wait until a primary has been elected
for (let i = 0; i < 60; i++) {
  const primary = rs.status().members.find((m) => m.stateStr === "PRIMARY");
  if (primary) { print(`primary is ${primary.name}`); quit(0); }
  sleep(1000);
}
print("no primary elected within 60s"); quit(1);
